// Google Play Billing (Billing Library 9 through in_app_purchase_android).
//
// Products: subscription `eventide_premium` (base plans `monthly`, `annual` with a 3-day trial),
// one-time `eventide_lifetime`, consumable `eventide_credits_50`. Every purchase is verified by
// the server (POST /purchases), which acknowledges or consumes it. Prices are read from Play;
// the dossier prices are only a display fallback when Play does not answer.
import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:in_app_purchase/in_app_purchase.dart';
import 'package:in_app_purchase_android/billing_client_wrappers.dart';
import 'package:in_app_purchase_android/in_app_purchase_android.dart';

import '../app/app_model.dart' show ProductOffer, PurchaseChoice;
import '../core/plan.dart';
import 'api_client.dart';

abstract final class ProductIds {
  static const premium = 'eventide_premium';
  static const lifetime = 'eventide_lifetime';
  static const credits = 'eventide_credits_50';
  static const monthlyPlan = 'monthly';
  static const annualPlan = 'annual';

  /// Credits granted locally by the debug-only acknowledgement path.
  static const creditsPerPack = 50;
}

/// Display fallback (dossier § 3) when Google Play is unavailable.
const List<ProductOffer> fallbackOffers = [
  ProductOffer(choice: PurchaseChoice.annual, price: '59,99 €', available: false, hasFreeTrial: true),
  ProductOffer(choice: PurchaseChoice.monthly, price: '7,99 €', available: false),
  ProductOffer(choice: PurchaseChoice.lifetime, price: '79,99 €', available: false),
];

sealed class BillingEvent {
  const BillingEvent();
}

/// Verified purchase: new entitlements (server body, or computed locally in debug).
class EntitlementsChanged extends BillingEvent {
  const EntitlementsChanged(this.entitlements);
  final Entitlements entitlements;
}

class PurchasePending extends BillingEvent {
  const PurchasePending();
}

class PurchaseFailed extends BillingEvent {
  const PurchaseFailed(this.message);
  final String message;
}

abstract class Billing {
  Stream<BillingEvent> get events;

  /// Starts listening to purchases. Call once, early (pending purchases are delivered here).
  Future<void> initialize();

  /// Offers priced by Google Play (fallback prices when Play is unavailable).
  Future<List<ProductOffer>> loadOffers();

  Future<void> buy(PurchaseChoice choice);
  Future<void> buyCredits();
  Future<void> restore();

  /// Price of the credits pack, when Play answered.
  String? get creditsPrice;
}

class PlayBilling implements Billing {
  PlayBilling({
    required this._api,
    required this._localAcknowledgement,
    required Entitlements Function() currentEntitlements,
    InAppPurchase? iap,
  })  : _current = currentEntitlements,
        _iap = iap ?? InAppPurchase.instance;

  final ApiClient _api;

  /// Debug builds without backend only: purchases are acknowledged on the phone, unverified.
  final bool _localAcknowledgement;
  final Entitlements Function() _current;
  final InAppPurchase _iap;

  final _events = StreamController<BillingEvent>.broadcast();
  StreamSubscription<List<PurchaseDetails>>? _subscription;
  final Map<String, GooglePlayProductDetails> _byOffer = {};
  GooglePlayProductDetails? _lifetime;
  GooglePlayProductDetails? _credits;

  /// Base plan asked for the last subscription purchase (sent to POST /purchases).
  String? _requestedBasePlan;

  @override
  Stream<BillingEvent> get events => _events.stream;

  @override
  String? get creditsPrice => _credits?.price;

  @override
  Future<void> initialize() async {
    _subscription ??= _iap.purchaseStream.listen(
      _onPurchases,
      onError: (Object e) => debugPrint('PlayBilling: purchase stream error ($e)'),
    );
  }

  @override
  Future<List<ProductOffer>> loadOffers() async {
    try {
      if (!await _iap.isAvailable()) return fallbackOffers;
      final response = await _iap.queryProductDetails({ProductIds.premium, ProductIds.lifetime, ProductIds.credits});
      _byOffer.clear();
      for (final details in response.productDetails.whereType<GooglePlayProductDetails>()) {
        switch (details.id) {
          case ProductIds.premium:
            final index = details.subscriptionIndex;
            final offers = details.productDetails.subscriptionOfferDetails;
            if (index == null || offers == null) continue;
            final offer = offers[index];
            final key = '${offer.basePlanId}/${offer.offerId ?? ''}';
            _byOffer[key] = details;
          case ProductIds.lifetime:
            _lifetime = details;
          case ProductIds.credits:
            _credits = details;
        }
      }
      return [
        _subscriptionOffer(PurchaseChoice.annual, ProductIds.annualPlan, fallbackOffers[0]),
        _subscriptionOffer(PurchaseChoice.monthly, ProductIds.monthlyPlan, fallbackOffers[1]),
        _lifetime == null
            ? fallbackOffers[2]
            : ProductOffer(choice: PurchaseChoice.lifetime, price: _lifetime!.price, available: true),
      ];
    } catch (e) {
      debugPrint('PlayBilling: cannot load offers ($e)');
      return fallbackOffers;
    }
  }

  /// The offer to buy for a base plan: the free-trial offer when there is one, else the base offer.
  GooglePlayProductDetails? _offerFor(String basePlan) {
    GooglePlayProductDetails? base;
    for (final entry in _byOffer.entries) {
      if (!entry.key.startsWith('$basePlan/')) continue;
      if (_hasFreeTrial(entry.value)) return entry.value;
      if (entry.key == '$basePlan/') base = entry.value;
      base ??= entry.value;
    }
    return base;
  }

  static SubscriptionOfferDetailsWrapper? _offerDetails(GooglePlayProductDetails d) {
    final index = d.subscriptionIndex;
    final offers = d.productDetails.subscriptionOfferDetails;
    if (index == null || offers == null || index >= offers.length) return null;
    return offers[index];
  }

  static bool _hasFreeTrial(GooglePlayProductDetails d) {
    final phases = _offerDetails(d)?.pricingPhases ?? const <PricingPhaseWrapper>[];
    return phases.length > 1 && phases.first.priceAmountMicros == 0;
  }

  /// Recurring price (last pricing phase), e.g. « 59,99 € » even when a trial comes first.
  static String _recurringPrice(GooglePlayProductDetails d) {
    final phases = _offerDetails(d)?.pricingPhases ?? const <PricingPhaseWrapper>[];
    return phases.isEmpty ? d.price : phases.last.formattedPrice;
  }

  ProductOffer _subscriptionOffer(PurchaseChoice choice, String basePlan, ProductOffer fallback) {
    final details = _offerFor(basePlan);
    if (details == null) return fallback;
    return ProductOffer(
      choice: choice,
      price: _recurringPrice(details),
      available: true,
      hasFreeTrial: _hasFreeTrial(details),
    );
  }

  @override
  Future<void> buy(PurchaseChoice choice) async {
    if (_byOffer.isEmpty && _lifetime == null) await loadOffers();
    switch (choice) {
      case PurchaseChoice.annual:
      case PurchaseChoice.monthly:
        final plan = choice == PurchaseChoice.annual ? ProductIds.annualPlan : ProductIds.monthlyPlan;
        final details = _offerFor(plan);
        if (details == null) {
          _events.add(const PurchaseFailed('Google Play ne répond pas. Réessayez plus tard.'));
          return;
        }
        _requestedBasePlan = plan;
        await _launch(() => _iap.buyNonConsumable(
              purchaseParam: GooglePlayPurchaseParam(productDetails: details, offerToken: details.offerToken),
            ));
      case PurchaseChoice.lifetime:
        final details = _lifetime;
        if (details == null) {
          _events.add(const PurchaseFailed('Google Play ne répond pas. Réessayez plus tard.'));
          return;
        }
        await _launch(() => _iap.buyNonConsumable(purchaseParam: GooglePlayPurchaseParam(productDetails: details)));
    }
  }

  @override
  Future<void> buyCredits() async {
    if (_credits == null) await loadOffers();
    final details = _credits;
    if (details == null) {
      _events.add(const PurchaseFailed('Google Play ne répond pas. Réessayez plus tard.'));
      return;
    }
    // The server consumes the pack after verification (autoConsume: false).
    await _launch(() => _iap.buyConsumable(
          purchaseParam: GooglePlayPurchaseParam(productDetails: details),
          autoConsume: false,
        ));
  }

  Future<void> _launch(Future<bool> Function() action) async {
    try {
      await action();
    } catch (e) {
      debugPrint('PlayBilling: launch failed ($e)');
      _events.add(const PurchaseFailed('L’achat n’a pas pu démarrer. Réessayez.'));
    }
  }

  @override
  Future<void> restore() async {
    try {
      await _iap.restorePurchases();
    } catch (e) {
      _events.add(const PurchaseFailed('Impossible de joindre Google Play. Réessayez plus tard.'));
    }
  }

  Future<void> _onPurchases(List<PurchaseDetails> purchases) async {
    for (final purchase in purchases) {
      switch (purchase.status) {
        case PurchaseStatus.pending:
          _events.add(const PurchasePending());
        case PurchaseStatus.canceled:
          await _complete(purchase);
        case PurchaseStatus.error:
          _events.add(const PurchaseFailed('L’achat n’a pas abouti. Aucun montant n’a été prélevé.'));
          await _complete(purchase);
        case PurchaseStatus.purchased:
        case PurchaseStatus.restored:
          await _verify(purchase);
      }
    }
  }

  Future<void> _complete(PurchaseDetails purchase) async {
    if (!purchase.pendingCompletePurchase) return;
    try {
      await _iap.completePurchase(purchase);
    } catch (e) {
      debugPrint('PlayBilling: completePurchase failed ($e)');
    }
  }

  Future<void> _verify(PurchaseDetails purchase) async {
    final token = purchase.verificationData.serverVerificationData;
    if (_api.enabled) {
      try {
        final body = await _api.postPurchase(
          productId: purchase.productID,
          purchaseToken: token,
          basePlanId: purchase.productID == ProductIds.premium ? _requestedBasePlan : null,
        );
        _events.add(EntitlementsChanged(Entitlements.fromJson(body)));
        // The server already acknowledged (or consumed) it; this only clears the client flag.
        await _complete(purchase);
      } on ApiException catch (e) {
        _events.add(PurchaseFailed(switch (e.code) {
          'purchase_owned_by_other_account' => 'Cet achat est déjà lié à un autre compte Google.',
          'purchase_invalid' => 'Google Play n’a pas confirmé cet achat.',
          _ => 'L’achat n’a pas pu être vérifié. Réessayez plus tard.',
        }));
      } on ApiUnavailableException {
        // Not acknowledged: Play keeps it pending; « Restaurer mes achats » or the next start
        // retries the verification (Google refunds it only after 3 days without acknowledgement).
        _events.add(const PurchaseFailed('Achat reçu. Il sera confirmé dès que la connexion revient.'));
      }
      return;
    }
    if (_localAcknowledgement) {
      // DEBUG ONLY, no backend: acknowledge/consume on the phone without any verification.
      await _complete(purchase);
      if (purchase.productID == ProductIds.credits) {
        try {
          final addition = _iap.getPlatformAddition<InAppPurchaseAndroidPlatformAddition>();
          await addition.consumePurchase(purchase);
        } catch (e) {
          debugPrint('PlayBilling: local consume failed ($e)');
        }
      }
      _events.add(EntitlementsChanged(_localEntitlements(purchase.productID)));
      return;
    }
    _events.add(const PurchaseFailed('L’achat ne peut pas être vérifié pour le moment.'));
  }

  Entitlements _localEntitlements(String productId) {
    final current = _current();
    switch (productId) {
      case ProductIds.lifetime:
        return Entitlements(
          plan: Plan.lifetime,
          premium: true,
          voice: VoiceQuota(mode: VoiceMode.credits, creditsRemaining: current.voice.creditsRemaining),
        );
      case ProductIds.credits:
        return Entitlements(
          plan: current.plan,
          premium: current.premium,
          expiresAt: current.expiresAt,
          autoRenewing: current.autoRenewing,
          voice: VoiceQuota(
            mode: current.plan == Plan.lifetime ? VoiceMode.credits : current.voice.mode,
            trialRemaining: current.voice.trialRemaining,
            creditsRemaining: current.voice.creditsRemaining + ProductIds.creditsPerPack,
          ),
        );
      default:
        final plan = _requestedBasePlan == ProductIds.monthlyPlan ? Plan.monthly : Plan.annual;
        return Entitlements(
          plan: plan,
          premium: true,
          autoRenewing: true,
          voice: const VoiceQuota(mode: VoiceMode.included),
        );
    }
  }
}
