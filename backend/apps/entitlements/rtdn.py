"""Real-time developer notifications (``POST /v1/play/rtdn``), Pub/Sub push.

Authentication: the OIDC token that Pub/Sub puts in ``Authorization`` (signed by Google), with
the expected audience and service account e-mail. The notification only says « something
changed for this token »: the state is always re-read at Google (``refresh``).
"""

from __future__ import annotations

import base64
import binascii
import json
import logging

from django.conf import settings

from . import purchases
from .models import Purchase

logger = logging.getLogger(__name__)


class RtdnUnauthorized(Exception):
    pass


class RtdnMalformed(Exception):
    pass


def verify_push_token(authorization: str) -> None:
    from google.auth import exceptions as google_exceptions
    from google.auth.transport import requests as google_requests
    from google.oauth2 import id_token

    if not settings.RTDN_AUDIENCE or not settings.RTDN_SERVICE_ACCOUNT_EMAIL:
        raise RtdnUnauthorized("not configured")
    scheme, _, token = authorization.partition(" ")
    if scheme.lower() != "bearer" or not token:
        raise RtdnUnauthorized("missing")
    try:
        claims = id_token.verify_oauth2_token(
            token, google_requests.Request(), audience=settings.RTDN_AUDIENCE
        )
    except (ValueError, google_exceptions.GoogleAuthError) as exc:
        raise RtdnUnauthorized("invalid") from exc
    if claims.get("email") != settings.RTDN_SERVICE_ACCOUNT_EMAIL or not claims.get(
        "email_verified"
    ):
        raise RtdnUnauthorized("service_account")


def decode(body: object) -> dict:
    if not isinstance(body, dict) or not isinstance(body.get("message"), dict):
        raise RtdnMalformed()
    data = body["message"].get("data")
    if not isinstance(data, str):
        raise RtdnMalformed()
    try:
        decoded = json.loads(base64.b64decode(data, validate=True))
    except (binascii.Error, ValueError) as exc:
        raise RtdnMalformed() from exc
    if not isinstance(decoded, dict):
        raise RtdnMalformed()
    return decoded


def handle(notification: dict) -> str:
    """Apply one notification; returns a short outcome label (logged, never the token)."""
    if notification.get("packageName") != settings.PLAY_PACKAGE_NAME:
        return "other_package"
    if "testNotification" in notification:
        return "test"
    token = None
    voided = False
    for key in ("subscriptionNotification", "oneTimeProductNotification"):
        part = notification.get(key)
        if isinstance(part, dict):
            token = part.get("purchaseToken")
    voided_part = notification.get("voidedPurchaseNotification")
    if isinstance(voided_part, dict):
        token = voided_part.get("purchaseToken")
        voided = True
    if not isinstance(token, str) or not token:
        return "ignored"
    purchase = Purchase.objects.filter(purchase_token=token).first()
    if purchase is None:
        # Not posted by the app yet: POST /purchases will record it.
        return "unknown_token"
    if voided:
        purchases.revoke(purchase)
        return "voided"
    purchases.refresh(purchase)  # PlayUnavailable propagates: 503, Pub/Sub retries
    return "refreshed"
