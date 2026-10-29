import 'dart:convert';

import 'package:eventide/core/catalog.dart';
import 'package:eventide/core/plan.dart';
import 'package:eventide/core/scene.dart';
import 'package:eventide/core/settings.dart';
import 'package:flutter_test/flutter_test.dart';

import 'test_helpers.dart';

void main() {
  final catalog = loadCatalog();

  group('AppSettings', () {
    test('defaults', () {
      const s = AppSettings();
      expect(s.textSize, 0);
      expect(s.textScale, 1.0);
      expect(s.textSizeLabel, 'Normale');
      expect(s.highContrast, isFalse);
      expect(s.blackScreenDuringTimer, isFalse);
      expect(s.wifiOnly, isFalse);
      expect(s.onboarded, isFalse);
    });

    test('text sizes', () {
      expect(const AppSettings(textSize: 1).textScale, 1.15);
      expect(const AppSettings(textSize: 1).textSizeLabel, 'Grande');
      expect(const AppSettings(textSize: 2).textScale, 1.3);
      expect(const AppSettings(textSize: 2).textSizeLabel, 'Très grande');
      expect(const AppSettings().copyWith(textSize: 5).textSize, 2);
      expect(const AppSettings().copyWith(textSize: -1).textSize, 0);
    });

    test('JSON round trip', () {
      const s = AppSettings(
        textSize: 2,
        highContrast: true,
        blackScreenDuringTimer: true,
        wifiOnly: true,
        onboarded: true,
      );
      expect(AppSettings.fromJson(s.toJson()), s);
      expect(s.toJson(), {
        'taille_texte': 2,
        'contraste_renforce': true,
        'ecran_noir_minuteur': true,
        'wifi_seulement': true,
        'onboarded': true,
      });
      expect(
        AppSettings.fromJson({'taille_texte': 9, 'contraste_renforce': 'oui'}),
        const AppSettings(textSize: 2),
      );
      expect(AppSettings.fromJson(const {}), const AppSettings());
    });
  });

  group('Plan and entitlements', () {
    test('premium plans', () {
      expect(Plan.free.isPremium, isFalse);
      expect(Plan.monthly.isPremium, isTrue);
      expect(Plan.annual.isPremium, isTrue);
      expect(Plan.lifetime.isPremium, isTrue);
      expect(Plan.fromId('annual'), Plan.annual);
      expect(Plan.fromId('gold'), Plan.free);
    });

    test('contract §6 example', () {
      final e = Entitlements.fromJson(
        jsonDecode(
          '''
{"plan": "free", "premium": false, "expires_at": null, "auto_renewing": false}''',
        ) as Map<String, dynamic>,
      );
      expect(e, Entitlements.free());
      expect(Entitlements.fromJson(e.toJson()), e);
      expect(e.toJson().keys, ['plan', 'premium', 'expires_at', 'auto_renewing']);
    });

    test('annual subscriber with expiry', () {
      final e = Entitlements.fromJson({
        'plan': 'annual',
        'premium': true,
        'expires_at': '2027-10-28T10:00:00Z',
        'auto_renewing': true,
        // A body cached by an earlier version (voice block, removed): ignored.
        'voice': {'mode': 'included'},
      });
      expect(e.plan, Plan.annual);
      expect(e.premium, isTrue);
      expect(e.expiresAt, DateTime.utc(2027, 10, 28, 10));
      expect(e.autoRenewing, isTrue);
      expect(Entitlements.fromJson(e.toJson()), e);
    });
  });

  group('ProductRules', () {
    final rules = ProductRules(catalog);

    test('landscapes', () {
      final free = catalog.landscape('sous-bois')!;
      final locked = catalog.landscape('aurore-boreale')!;
      expect(rules.canUseLandscape(Plan.free, free), isTrue);
      expect(rules.canUseLandscape(Plan.free, locked), isFalse);
      for (final p in [Plan.monthly, Plan.annual, Plan.lifetime]) {
        expect(rules.canUseLandscape(p, locked), isTrue);
      }
    });

    test('items', () {
      expect(rules.canUseItem(Plan.free, LayerKind.son, 'pluie-douce'), isTrue);
      expect(rules.canUseItem(Plan.free, LayerKind.son, 'tonnerre'), isFalse);
      expect(
        rules.canUseItem(Plan.lifetime, LayerKind.son, 'tonnerre'),
        isTrue,
      );
      expect(rules.canUseItem(Plan.annual, LayerKind.son, 'licorne'), isFalse);
      expect(
        rules.canUseItem(Plan.free, LayerKind.musique, 'piano-doux'),
        isTrue,
      );
      expect(rules.canUseItem(Plan.free, LayerKind.decor, 'etoiles'), isFalse);
    });

    test('limits by plan', () {
      expect(rules.maxSchedules(Plan.free), 1);
      expect(rules.maxSchedules(Plan.monthly), isNull);
      expect(rules.maxFavorites(Plan.free), 3);
      expect(rules.maxFavorites(Plan.lifetime), isNull);
      expect(rules.offlineAllowed(Plan.free), isFalse);
      expect(rules.offlineAllowed(Plan.annual), isTrue);
      expect(rules.showsAds(Plan.free), isTrue);
      expect(rules.showsAds(Plan.lifetime), isFalse);
      expect(rules.sleepHistory(Plan.free), isFalse);
      expect(rules.sleepHistory(Plan.monthly), isTrue);
    });

    test('locked elements of a received mix', () {
      final scene = Scene.fromLandscape(catalog.landscape('toits-pluie')!);
      expect(rules.lockedElements(Plan.annual, scene), isEmpty);
      final locked = rules.lockedElements(Plan.free, scene);
      expect(locked, [
        (kind: null, id: 'toits-pluie'),
        (kind: LayerKind.son, id: 'ambiance-toits-pluie'),
        (kind: LayerKind.son, id: 'tonnerre'),
        (kind: LayerKind.musique, id: 'cordes-lentes'),
        (kind: LayerKind.decor, id: 'eclairs'),
      ]);
    });
  });
}
