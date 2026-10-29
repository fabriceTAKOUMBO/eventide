"""Google Play Developer API (``androidpublisher`` v3) through the service account.

- ``purchases.subscriptionsv2.get`` for the subscription ``eventide_premium``;
- ``purchases.products.get`` for the one-time product ``eventide_lifetime``;
- ``acknowledge`` (subscription, one-time product), within 3 days.
"""

from __future__ import annotations

import logging
from dataclasses import dataclass
from datetime import UTC, datetime
from urllib.parse import quote

import requests
from django.conf import settings

from apps.core.google import GoogleNotConfigured, authorized_session

logger = logging.getLogger(__name__)

API = "https://androidpublisher.googleapis.com/androidpublisher/v3/applications/{package}"


class PlayInvalid(Exception):
    """Google does not know this token for this product (402 purchase_invalid)."""


class PlayUnavailable(Exception):
    """Google could not be reached, refused our credentials or is not configured (503)."""


@dataclass(frozen=True)
class SubscriptionState:
    state: str  # Purchase.State value
    product_id: str
    base_plan_id: str
    expires_at: datetime | None
    auto_renewing: bool
    acknowledged: bool
    order_id: str
    linked_purchase_token: str


@dataclass(frozen=True)
class ProductState:
    state: str  # Purchase.State value
    acknowledged: bool
    order_id: str


SUBSCRIPTION_STATES = {
    "SUBSCRIPTION_STATE_ACTIVE": "active",
    "SUBSCRIPTION_STATE_CANCELED": "canceled",
    "SUBSCRIPTION_STATE_IN_GRACE_PERIOD": "in_grace",
    "SUBSCRIPTION_STATE_ON_HOLD": "on_hold",
    "SUBSCRIPTION_STATE_PAUSED": "paused",
    "SUBSCRIPTION_STATE_EXPIRED": "expired",
    "SUBSCRIPTION_STATE_PENDING": "pending",
    "SUBSCRIPTION_STATE_PENDING_PURCHASE_CANCELED": "expired",
}
# purchases.products: purchaseState 0 = purchased, 1 = canceled, 2 = pending.
PRODUCT_STATES = {0: "active", 1: "revoked", 2: "pending"}


def _parse_time(value: str | None) -> datetime | None:
    if not value:
        return None
    try:
        return datetime.fromisoformat(value.replace("Z", "+00:00")).astimezone(UTC)
    except ValueError:
        return None


def _call(method: str, url: str, **kwargs) -> requests.Response:
    try:
        session = authorized_session()
        response = session.request(
            method, url, timeout=settings.GOOGLE_API_TIMEOUT_SECONDS, **kwargs
        )
    except GoogleNotConfigured as exc:
        logger.error("Play Developer API not configured", extra={"event": "google_not_configured"})
        raise PlayUnavailable() from exc
    except (requests.RequestException, OSError) as exc:
        logger.warning("Play Developer API unreachable", extra={"event": "play_api_unavailable"})
        raise PlayUnavailable() from exc
    if response.status_code in (400, 404, 410):
        raise PlayInvalid()
    if response.status_code in (401, 403):
        logger.error(
            "Play Developer API refused our credentials",
            extra={"event": "play_api_auth_error", "status": response.status_code},
        )
        raise PlayUnavailable()
    if response.status_code >= 300:
        logger.warning(
            "Play Developer API error",
            extra={"event": "play_api_unavailable", "status": response.status_code},
        )
        raise PlayUnavailable()
    return response


def _base() -> str:
    return API.format(package=quote(settings.PLAY_PACKAGE_NAME, safe=""))


def _token(token: str) -> str:
    return quote(token, safe="")


def get_subscription(token: str) -> SubscriptionState:
    response = _call("GET", f"{_base()}/purchases/subscriptionsv2/tokens/{_token(token)}")
    try:
        data = response.json()
    except ValueError as exc:
        raise PlayUnavailable() from exc
    items = data.get("lineItems") or []
    item = max(items, key=lambda i: i.get("expiryTime", ""), default={})
    product_id = item.get("productId", "")
    if product_id != settings.PLAY_SUBSCRIPTION_PRODUCT_ID:
        raise PlayInvalid()
    return SubscriptionState(
        state=SUBSCRIPTION_STATES.get(data.get("subscriptionState", ""), "expired"),
        product_id=product_id,
        base_plan_id=(item.get("offerDetails") or {}).get("basePlanId", ""),
        expires_at=_parse_time(item.get("expiryTime")),
        auto_renewing=bool((item.get("autoRenewingPlan") or {}).get("autoRenewEnabled", False)),
        acknowledged=data.get("acknowledgementState") == "ACKNOWLEDGEMENT_STATE_ACKNOWLEDGED",
        order_id=str(data.get("latestOrderId", ""))[:64],
        linked_purchase_token=data.get("linkedPurchaseToken", "") or "",
    )


def get_product(product_id: str, token: str) -> ProductState:
    response = _call(
        "GET", f"{_base()}/purchases/products/{quote(product_id, safe='')}/tokens/{_token(token)}"
    )
    try:
        data = response.json()
        purchase_state = int(data.get("purchaseState", -1))
    except (ValueError, TypeError) as exc:
        raise PlayUnavailable() from exc
    return ProductState(
        state=PRODUCT_STATES.get(purchase_state, "revoked"),
        acknowledged=int(data.get("acknowledgementState", 0)) == 1,
        order_id=str(data.get("orderId", ""))[:64],
    )


def acknowledge_subscription(token: str) -> None:
    subscription = quote(settings.PLAY_SUBSCRIPTION_PRODUCT_ID, safe="")
    _call(
        "POST",
        f"{_base()}/purchases/subscriptions/{subscription}/tokens/{_token(token)}:acknowledge",
        json={},
    )


def acknowledge_product(product_id: str, token: str) -> None:
    _call(
        "POST",
        f"{_base()}/purchases/products/{quote(product_id, safe='')}/tokens/{_token(token)}"
        ":acknowledge",
        json={},
    )
