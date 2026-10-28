"""Purchase verification, recording and finalisation (contract § 6).

Google is always called OUTSIDE a database transaction; the recording that follows is atomic
and idempotent on ``purchase_token``: the same token presented again refreshes its state and
never grants credits twice.
"""

from __future__ import annotations

import logging
from datetime import timedelta

from django.conf import settings
from django.db import IntegrityError, transaction
from django.db.models import F
from django.utils import timezone

from apps.accounts.models import Account
from apps.installations.models import Installation

from . import play
from .models import Purchase
from .services import Owner

logger = logging.getLogger(__name__)

FINALISATION_WINDOW = timedelta(days=3)


class PurchaseOwnedByOther(Exception):
    """409 purchase_owned_by_other_account."""


class PurchaseInvalid(Exception):
    """402 purchase_invalid."""


def kind_of(product_id: str) -> str | None:
    if product_id == settings.PLAY_SUBSCRIPTION_PRODUCT_ID:
        return Purchase.Kind.SUBSCRIPTION
    if product_id == settings.PLAY_LIFETIME_PRODUCT_ID:
        return Purchase.Kind.LIFETIME
    if product_id in settings.PLAY_CREDIT_PRODUCTS:
        return Purchase.Kind.CREDITS
    return None


def _fetch(kind: str, product_id: str, token: str) -> dict:
    """Current state at Google, as Purchase fields (plus finalisation flags)."""
    if kind == Purchase.Kind.SUBSCRIPTION:
        sub = play.get_subscription(token)
        return {
            "state": sub.state,
            "base_plan_id": sub.base_plan_id,
            "expires_at": sub.expires_at,
            "auto_renewing": sub.auto_renewing,
            "order_id": sub.order_id,
            "google_acknowledged": sub.acknowledged,
            "linked_purchase_token": sub.linked_purchase_token,
        }
    product = play.get_product(product_id, token)
    return {
        "state": product.state,
        "base_plan_id": "",
        "expires_at": None,
        "auto_renewing": False,
        "order_id": product.order_id,
        "google_acknowledged": product.acknowledged,
        "google_consumed": product.consumed,
        "quantity": product.quantity,
    }


def _holder_model(purchase: Purchase):
    if purchase.account_id is not None:
        return Account, purchase.account_id
    return Installation, purchase.installation_id


def _grant_credits(purchase: Purchase, quantity: int) -> None:
    """Credits of a consumable, granted exactly once (conditional update on the purchase)."""
    amount = settings.PLAY_CREDIT_PRODUCTS[purchase.product_id] * quantity
    granted = Purchase.objects.filter(pk=purchase.pk, credits_granted=0).update(
        credits_granted=amount
    )
    if granted:
        model, pk = _holder_model(purchase)
        model.objects.filter(pk=pk).update(credits=F("credits") + amount)
        purchase.credits_granted = amount
        logger.info("Voice credits granted", extra={"event": "credits_granted", "amount": amount})


def _revoke_credits(purchase: Purchase) -> None:
    """Refunded consumable: take back what is left of its credits (never below zero)."""
    if purchase.credits_granted <= 0:
        return
    model, pk = _holder_model(purchase)
    holder = model.objects.select_for_update().get(pk=pk)
    taken = min(holder.credits, purchase.credits_granted)
    model.objects.filter(pk=pk).update(credits=F("credits") - taken)


def _record(
    *,
    owner: Owner | None,
    existing: Purchase | None,
    token: str,
    product_id: str,
    kind: str,
    state: dict,
) -> Purchase:
    now = timezone.now()
    fields = {
        "product_id": product_id,
        "kind": kind,
        "state": state["state"],
        "base_plan_id": state["base_plan_id"],
        "expires_at": state["expires_at"],
        "auto_renewing": state["auto_renewing"],
        "order_id": state["order_id"],
        "last_verified_at": now,
    }
    if state.get("google_acknowledged"):
        fields["acknowledged"] = True
    if state.get("google_consumed"):
        fields["consumed"] = True
    with transaction.atomic():
        if existing is None:
            if owner is None:  # only RTDN updates existing purchases without an owner
                raise ValueError("a new purchase needs an owner")
            purchase = Purchase.objects.create(purchase_token=token, **owner.fields, **fields)
        else:
            purchase = Purchase.objects.select_for_update().get(pk=existing.pk)
            previous_state = purchase.state
            for name, value in fields.items():
                setattr(purchase, name, value)
            purchase.save()
            if (
                kind == Purchase.Kind.CREDITS
                and state["state"] == Purchase.State.REVOKED
                and previous_state != Purchase.State.REVOKED
            ):
                _revoke_credits(purchase)
        if kind == Purchase.Kind.CREDITS and purchase.state == Purchase.State.ACTIVE:
            _grant_credits(purchase, state.get("quantity", 1))
        linked = state.get("linked_purchase_token")
        if linked:
            # Upgrade, downgrade or resubscription: the previous token no longer entitles.
            Purchase.objects.filter(purchase_token=linked).exclude(pk=purchase.pk).update(
                state=Purchase.State.REPLACED
            )
    return purchase


def finalise(purchase: Purchase) -> bool:
    """Acknowledge (subscription, lifetime) or consume (credits) at Google; True when done."""
    try:
        if purchase.kind == Purchase.Kind.CREDITS:
            if purchase.consumed or purchase.state != Purchase.State.ACTIVE:
                return True
            if not purchase.credits_granted:
                return False
            play.consume_product(purchase.product_id, purchase.purchase_token)
            Purchase.objects.filter(pk=purchase.pk).update(consumed=True, acknowledged=True)
            purchase.consumed = True
            return True
        if purchase.acknowledged or purchase.state not in Purchase.ENTITLED_SUBSCRIPTION_STATES:
            return True
        if purchase.kind == Purchase.Kind.SUBSCRIPTION:
            play.acknowledge_subscription(purchase.purchase_token)
        else:
            play.acknowledge_product(purchase.product_id, purchase.purchase_token)
        Purchase.objects.filter(pk=purchase.pk).update(acknowledged=True)
        purchase.acknowledged = True
        return True
    except (play.PlayInvalid, play.PlayUnavailable):
        logger.warning(
            "Purchase finalisation failed (retried by finalize_purchases)",
            extra={"event": "purchase_finalization_failed", "kind": purchase.kind},
        )
        return False


def submit(owner: Owner, *, product_id: str, token: str) -> Purchase:
    """POST /purchases: verify at Google, record (idempotent), finalise.

    Raises PurchaseOwnedByOther, PurchaseInvalid, or play.PlayUnavailable.
    """
    kind = kind_of(product_id)
    if kind is None:  # pragma: no cover - the view validates product_id first
        raise PurchaseInvalid()
    existing = Purchase.objects.filter(purchase_token=token).first()
    if existing is not None and not owner.owns(existing):
        raise PurchaseOwnedByOther()
    if existing is not None and existing.product_id != product_id:
        raise PurchaseInvalid()
    try:
        state = _fetch(kind, product_id, token)
    except play.PlayInvalid as exc:
        raise PurchaseInvalid() from exc
    if state["state"] in (Purchase.State.REVOKED, Purchase.State.EXPIRED) and existing is None:
        raise PurchaseInvalid()
    try:
        purchase = _record(
            owner=owner,
            existing=existing,
            token=token,
            product_id=product_id,
            kind=kind,
            state=state,
        )
    except IntegrityError:
        # The same token recorded concurrently: the second request reads the first one.
        existing = Purchase.objects.get(purchase_token=token)
        if not owner.owns(existing):
            raise PurchaseOwnedByOther() from None
        purchase = _record(
            owner=owner,
            existing=existing,
            token=token,
            product_id=product_id,
            kind=kind,
            state=state,
        )
    if purchase.state in (Purchase.State.REVOKED, Purchase.State.EXPIRED):
        raise PurchaseInvalid()
    finalise(purchase)
    return purchase


def refresh(purchase: Purchase) -> Purchase:
    """Re-read a known purchase at Google (RTDN). PlayUnavailable propagates (Pub/Sub retries)."""
    try:
        state = _fetch(purchase.kind, purchase.product_id, purchase.purchase_token)
    except play.PlayInvalid:
        state = {
            "state": Purchase.State.REVOKED,
            "base_plan_id": purchase.base_plan_id,
            "expires_at": purchase.expires_at,
            "auto_renewing": False,
            "order_id": purchase.order_id,
        }
    updated = _record(
        owner=None,
        existing=purchase,
        token=purchase.purchase_token,
        product_id=purchase.product_id,
        kind=purchase.kind,
        state=state,
    )
    finalise(updated)
    return updated


def revoke(purchase: Purchase) -> None:
    """Voided purchase notification (refund, chargeback)."""
    with transaction.atomic():
        locked = Purchase.objects.select_for_update().get(pk=purchase.pk)
        if locked.state == Purchase.State.REVOKED:
            return
        locked.state = Purchase.State.REVOKED
        locked.auto_renewing = False
        locked.save(update_fields=["state", "auto_renewing", "updated_at"])
        if locked.kind == Purchase.Kind.CREDITS:
            _revoke_credits(locked)
    logger.info("Purchase revoked", extra={"event": "purchase_revoked", "kind": purchase.kind})


def pending_finalisation():
    since = timezone.now() - FINALISATION_WINDOW
    credits = Purchase.objects.filter(
        kind=Purchase.Kind.CREDITS,
        state=Purchase.State.ACTIVE,
        consumed=False,
        created_at__gte=since,
    )
    others = Purchase.objects.filter(
        kind__in=[Purchase.Kind.SUBSCRIPTION, Purchase.Kind.LIFETIME],
        state__in=Purchase.ENTITLED_SUBSCRIPTION_STATES,
        acknowledged=False,
        created_at__gte=since,
    )
    return list(credits) + list(others)
