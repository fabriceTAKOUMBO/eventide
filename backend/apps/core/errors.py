"""Error envelope of the contract: ``{"error": "<code>", "detail": "<short text>"}``.

``detail`` is a short, fixed text: it never echoes a request value (no personal data).
"""

from __future__ import annotations

import logging
from typing import Any

from django.core.exceptions import RequestDataTooBig
from django.http import Http404, JsonResponse
from rest_framework import exceptions as drf
from rest_framework.response import Response

logger = logging.getLogger(__name__)


class APIError(Exception):
    """An error with a stable contract code."""

    status = 400
    code = "invalid_request"
    detail = "Requête invalide."

    def __init__(self, detail: str | None = None, *, headers: dict[str, str] | None = None):
        super().__init__(detail or self.detail)
        if detail:
            self.detail = detail
        self.headers = headers or {}


class InvalidRequest(APIError):
    status = 400
    code = "invalid_request"
    detail = "Requête invalide."


class NotFound(APIError):
    status = 404
    code = "not_found"
    detail = "Introuvable."


class RateLimited(APIError):
    status = 429
    code = "rate_limited"
    detail = "Trop de demandes, réessayez plus tard."

    def __init__(self, retry_after: int):
        super().__init__(headers={"Retry-After": str(max(1, int(retry_after)))})


class ServiceUnavailable(APIError):
    status = 503
    code = "service_unavailable"
    detail = "Service momentanément indisponible."


def error_body(code: str, detail: str) -> dict[str, str]:
    return {"error": code, "detail": detail}


def _drf_mapping(exc: Exception) -> tuple[int, str, str] | None:
    if isinstance(exc, drf.NotAuthenticated | drf.AuthenticationFailed):
        return 401, "unauthorized", "Jeton d'installation absent ou invalide."
    if isinstance(exc, drf.PermissionDenied):
        return 403, "forbidden", "Action non autorisée."
    if isinstance(exc, drf.NotFound | Http404):
        return 404, "not_found", "Introuvable."
    if isinstance(exc, drf.MethodNotAllowed):
        return 405, "method_not_allowed", "Méthode non autorisée."
    if isinstance(exc, drf.UnsupportedMediaType):
        return 415, "unsupported_media_type", "Le corps doit être du JSON."
    if isinstance(exc, drf.Throttled):
        return 429, "rate_limited", "Trop de demandes, réessayez plus tard."
    if isinstance(exc, drf.ParseError | drf.ValidationError):
        return 400, "invalid_request", "Requête invalide."
    if isinstance(exc, RequestDataTooBig):
        return 413, "payload_too_large", "Corps de requête trop volumineux."
    return None


def exception_handler(exc: Exception, context: dict[str, Any]) -> Response | None:
    """DRF exception handler producing the contract envelope."""
    if isinstance(exc, APIError):
        return Response(error_body(exc.code, exc.detail), status=exc.status, headers=exc.headers)
    mapped = _drf_mapping(exc)
    if mapped is None:
        return None  # unexpected: Django answers 500 (handler500 below, JSON)
    status, code, detail = mapped
    headers = {}
    if status == 401:
        headers["WWW-Authenticate"] = 'Bearer realm="eventide"'
    return Response(error_body(code, detail), status=status, headers=headers)


def json_404(request, exception=None) -> JsonResponse:
    return JsonResponse(error_body("not_found", "Introuvable."), status=404)


def json_500(request) -> JsonResponse:
    return JsonResponse(error_body("server_error", "Erreur interne."), status=500)
