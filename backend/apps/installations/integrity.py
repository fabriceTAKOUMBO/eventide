"""Play Integrity verification (standard request, ``decodeIntegrityToken``), contract § 4.

The verdict must come from the Play-recognised app, on a device meeting the required
integrity, bound to this request (``requestHash``) and recent. ``PLAY_INTEGRITY_ENFORCED=false``
skips the check (development only; ``check --deploy`` warns).
"""

from __future__ import annotations

import logging
import time

import requests
from django.conf import settings

from apps.core.google import GoogleNotConfigured, authorized_session

logger = logging.getLogger(__name__)

ENDPOINT = "https://playintegrity.googleapis.com/v1/{package}:decodeIntegrityToken"
FUTURE_TOLERANCE_MS = 60_000


class IntegrityFailed(Exception):
    """The token is invalid or the verdict is not good enough (403 integrity_failed)."""


class IntegrityUnavailable(Exception):
    """Google could not be reached or is not configured (503 integrity_unavailable)."""


def _check_payload(payload: dict, request_hash: str) -> str | None:
    """Reason of the refusal, or None when the verdict is acceptable."""
    details = payload.get("requestDetails") or {}
    if details.get("requestPackageName") != settings.PLAY_PACKAGE_NAME:
        return "package"
    if details.get("requestHash") != request_hash:
        return "request_hash"
    try:
        stamp = int(details.get("timestampMillis", "0"))
    except (TypeError, ValueError):
        return "timestamp"
    now_ms = int(time.time() * 1000)
    if stamp > now_ms + FUTURE_TOLERANCE_MS or now_ms - stamp > (
        settings.PLAY_INTEGRITY_MAX_AGE_SECONDS * 1000
    ):
        return "timestamp"
    app = payload.get("appIntegrity") or {}
    if app.get("appRecognitionVerdict") != "PLAY_RECOGNIZED":
        return "app"
    device = (payload.get("deviceIntegrity") or {}).get("deviceRecognitionVerdict") or []
    if settings.PLAY_INTEGRITY_REQUIRED_DEVICE_VERDICT not in device:
        return "device"
    return None


def verify(integrity_token: str, request_hash: str) -> None:
    if not settings.PLAY_INTEGRITY_ENFORCED:
        return
    if not integrity_token:
        logger.info(
            "Integrity token missing", extra={"event": "integrity_failed", "reason": "missing"}
        )
        raise IntegrityFailed("missing")
    try:
        session = authorized_session()
        response = session.post(
            ENDPOINT.format(package=settings.PLAY_PACKAGE_NAME),
            json={"integrity_token": integrity_token},
            timeout=settings.GOOGLE_API_TIMEOUT_SECONDS,
        )
    except GoogleNotConfigured as exc:
        logger.error("Play Integrity not configured", extra={"event": "google_not_configured"})
        raise IntegrityUnavailable() from exc
    except (requests.RequestException, OSError) as exc:
        logger.warning("Play Integrity unreachable", extra={"event": "play_integrity_unavailable"})
        raise IntegrityUnavailable() from exc
    if response.status_code == 400:
        raise IntegrityFailed("token")
    if response.status_code != 200:
        logger.warning(
            "Play Integrity error",
            extra={"event": "play_integrity_unavailable", "status": response.status_code},
        )
        raise IntegrityUnavailable()
    try:
        payload = response.json()["tokenPayloadExternal"]
    except (ValueError, KeyError, TypeError) as exc:
        raise IntegrityUnavailable() from exc
    reason = _check_payload(payload, request_hash)
    if reason:
        logger.info(
            "Integrity verdict refused", extra={"event": "integrity_failed", "reason": reason}
        )
        raise IntegrityFailed(reason)
