"""Health probes (before host validation) and request ids."""

from __future__ import annotations

import logging
import uuid
from collections.abc import Callable

from django.core.exceptions import RequestDataTooBig
from django.db import connection
from django.http import HttpRequest, HttpResponse, JsonResponse

from .logging import request_id_var

logger = logging.getLogger(__name__)

HEALTH_PATH = "/v1/health"
READY_PATH = "/v1/health/ready"


def database_ready() -> bool:
    try:
        with connection.cursor() as cursor:
            cursor.execute("SELECT 1")
            return cursor.fetchone() == (1,)
    except Exception:  # any driver error means "not ready"
        logger.warning("Readiness check failed", extra={"event": "readiness_failed"})
        return False


class HealthCheckMiddleware:
    """``GET /v1/health`` (no database) and ``GET /v1/health/ready`` (database), contract § 10."""

    def __init__(self, get_response: Callable[[HttpRequest], HttpResponse]):
        self.get_response = get_response

    def __call__(self, request: HttpRequest) -> HttpResponse:
        if request.method in ("GET", "HEAD"):
            if request.path == HEALTH_PATH:
                return JsonResponse({"status": "ok"})
            if request.path == READY_PATH:
                if database_ready():
                    return JsonResponse({"status": "ok"})
                return JsonResponse({"status": "unavailable"}, status=503)
        return self.get_response(request)


class RequestIdMiddleware:
    def __init__(self, get_response: Callable[[HttpRequest], HttpResponse]):
        self.get_response = get_response

    def __call__(self, request: HttpRequest) -> HttpResponse:
        incoming = request.META.get("HTTP_X_AMZN_TRACE_ID", "")
        rid = incoming[-35:] if incoming else uuid.uuid4().hex
        token = request_id_var.set(rid)
        try:
            response = self.get_response(request)
        finally:
            request_id_var.reset(token)
        response["X-Request-Id"] = rid
        return response


class RequestSizeLimitMiddleware:
    """Reads the body once so that ``DATA_UPLOAD_MAX_MEMORY_SIZE`` applies to every request
    (DRF parsers otherwise stream the body without that check): 413 payload_too_large."""

    def __init__(self, get_response: Callable[[HttpRequest], HttpResponse]):
        self.get_response = get_response

    def __call__(self, request: HttpRequest) -> HttpResponse:
        if request.method in ("POST", "PUT", "PATCH", "DELETE"):
            try:
                request.body  # noqa: B018 - enforces the size limit
            except RequestDataTooBig:
                return JsonResponse(
                    {"error": "payload_too_large", "detail": "Corps de requête trop volumineux."},
                    status=413,
                )
        return self.get_response(request)
