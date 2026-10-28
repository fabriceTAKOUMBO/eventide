"""``POST /v1/account/google``, ``GET /v1/account/export``, ``DELETE /v1/account``."""

from __future__ import annotations

from django.conf import settings
from rest_framework.response import Response
from rest_framework.views import APIView

from apps.core import ratelimit
from apps.core.errors import APIError, InvalidRequest

from . import google_token, services


class InvalidGoogleTokenError(APIError):
    status = 401
    code = "invalid_google_token"
    detail = "Jeton Google invalide."


class GoogleUnavailableError(APIError):
    status = 503
    code = "google_unavailable"
    detail = "Google est momentanément injoignable."


class GoogleLinkView(APIView):
    def post(self, request):
        data = request.data
        token = data.get("id_token") if isinstance(data, dict) else None
        if not isinstance(token, str) or not 1 <= len(token) <= 8192:
            raise InvalidRequest()
        ratelimit.hit(
            "account_link",
            str(request.user.pk),
            limit=settings.RATE_ACCOUNT_LINK_PER_HOUR,
            window_seconds=ratelimit.HOUR,
        )
        try:
            sub = google_token.verify(token)
        except google_token.InvalidGoogleToken as exc:
            raise InvalidGoogleTokenError() from exc
        except google_token.GoogleUnavailable as exc:
            raise GoogleUnavailableError() from exc
        account = services.link(request.user, sub)
        return Response({"account_id": str(account.id), "linked": True})


class AccountExportView(APIView):
    def get(self, request):
        ratelimit.hit(
            "account_export",
            str(request.user.pk),
            limit=settings.RATE_EXPORT_PER_HOUR,
            window_seconds=ratelimit.HOUR,
        )
        return Response(services.export(request.user))


class AccountView(APIView):
    def delete(self, request):
        services.delete(request.user)
        return Response(status=204)
