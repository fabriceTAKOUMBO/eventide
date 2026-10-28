"""``GET /v1/entitlements``, ``POST /v1/purchases``, ``POST /v1/play/rtdn`` (contract § 6)."""

from __future__ import annotations

import logging

from django.conf import settings
from rest_framework.permissions import AllowAny
from rest_framework.response import Response
from rest_framework.views import APIView

from apps.core import ratelimit
from apps.core.errors import APIError, InvalidRequest

from . import play, purchases, rtdn
from .services import entitlements_body, owner_of

logger = logging.getLogger(__name__)


class PurchaseInvalidError(APIError):
    status = 402
    code = "purchase_invalid"
    detail = "Achat non reconnu par Google Play."


class PurchaseOwnedError(APIError):
    status = 409
    code = "purchase_owned_by_other_account"
    detail = "Cet achat est déjà rattaché à un autre compte ou appareil."


class PlayUnavailableError(APIError):
    status = 503
    code = "play_unavailable"
    detail = "Google Play est momentanément injoignable."


class EntitlementsView(APIView):
    def get(self, request):
        return Response(entitlements_body(request.user))


def _parse_purchase(data: object) -> tuple[str, str]:
    if not isinstance(data, dict):
        raise InvalidRequest()
    product_id = data.get("product_id")
    token = data.get("purchase_token")
    base_plan = data.get("base_plan_id")
    kind = purchases.kind_of(product_id) if isinstance(product_id, str) else None
    if kind is None:
        raise InvalidRequest()
    if not isinstance(token, str) or not 1 <= len(token) <= 4096:
        raise InvalidRequest()
    if kind == "subscription":
        if base_plan is not None and base_plan not in settings.PLAY_SUBSCRIPTION_BASE_PLANS:
            raise InvalidRequest()
    elif base_plan is not None:
        raise InvalidRequest()
    return product_id, token


class PurchasesView(APIView):
    def post(self, request):
        product_id, token = _parse_purchase(request.data)
        ratelimit.hit(
            "purchases",
            str(request.user.pk),
            limit=settings.RATE_PURCHASES_PER_HOUR,
            window_seconds=ratelimit.HOUR,
        )
        try:
            purchases.submit(owner_of(request.user), product_id=product_id, token=token)
        except purchases.PurchaseOwnedByOther as exc:
            raise PurchaseOwnedError() from exc
        except purchases.PurchaseInvalid as exc:
            raise PurchaseInvalidError() from exc
        except play.PlayUnavailable as exc:
            raise PlayUnavailableError() from exc
        return Response(entitlements_body(request.user))


class RtdnView(APIView):
    authentication_classes: list = []
    permission_classes = [AllowAny]

    def post(self, request):
        try:
            rtdn.verify_push_token(request.headers.get("Authorization", ""))
        except rtdn.RtdnUnauthorized as exc:
            logger.warning("RTDN refused", extra={"event": "rtdn_rejected", "reason": str(exc)})
            return Response(
                {"error": "unauthorized", "detail": "Jeton Pub/Sub invalide."}, status=401
            )
        try:
            notification = rtdn.decode(request.data)
        except rtdn.RtdnMalformed as exc:
            raise InvalidRequest() from exc
        try:
            outcome = rtdn.handle(notification)
        except play.PlayUnavailable as exc:
            raise PlayUnavailableError() from exc
        logger.info("RTDN processed", extra={"event": "rtdn_processed", "outcome": outcome})
        return Response(status=204)
