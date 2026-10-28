"""``POST /v1/installations`` (contract § 4)."""

from __future__ import annotations

import logging
import re

from django.conf import settings
from django.db import IntegrityError, transaction
from django.utils import timezone
from rest_framework.permissions import AllowAny
from rest_framework.response import Response
from rest_framework.views import APIView

from apps.core import ratelimit
from apps.core.clientip import ip_key
from apps.core.errors import APIError, InvalidRequest

from . import integrity
from .models import Installation
from .tokens import hash_token, new_token

logger = logging.getLogger(__name__)

DEVICE_HASH_RE = re.compile(r"^[0-9a-f]{64}$")
REQUEST_HASH_RE = re.compile(r"^[A-Za-z0-9_-]{43}$")
APP_VERSION_RE = re.compile(r"^[0-9]{1,4}\.[0-9]{1,4}\.[0-9]{1,4}([+-][0-9A-Za-z.-]{1,16})?$")


class IntegrityFailedError(APIError):
    status = 403
    code = "integrity_failed"
    detail = "Vérification de l'appareil refusée."


class IntegrityUnavailableError(APIError):
    status = 503
    code = "integrity_unavailable"
    detail = "Vérification de l'appareil momentanément impossible."


def _parse(data: object) -> tuple[str, str, str, str]:
    if not isinstance(data, dict):
        raise InvalidRequest()
    token = data.get("integrity_token")
    request_hash = data.get("request_hash")
    device_hash = data.get("device_hash")
    app_version = data.get("app_version")
    # Empty token: Play Integrity unavailable on the device (debug or sideloaded build). Accepted
    # only when PLAY_INTEGRITY_ENFORCED=false; otherwise integrity.verify() refuses it (403).
    if not isinstance(token, str) or len(token) > 8192:
        raise InvalidRequest()
    if not isinstance(request_hash, str) or not REQUEST_HASH_RE.match(request_hash):
        raise InvalidRequest()
    if not isinstance(device_hash, str) or not DEVICE_HASH_RE.match(device_hash):
        raise InvalidRequest()
    if not isinstance(app_version, str) or not APP_VERSION_RE.match(app_version):
        raise InvalidRequest()
    return token, request_hash, device_hash, app_version


def register(device_hash: str, app_version: str) -> tuple[Installation, str]:
    """Create the installation of this device, or rotate its token (the old one is revoked)."""
    token = new_token()
    now = timezone.now()
    fields = {
        "token_hash": hash_token(token),
        "token_issued_at": now,
        "app_version": app_version,
        "last_seen_at": now,
    }
    for _ in range(2):
        try:
            with transaction.atomic():
                installation = (
                    Installation.objects.select_for_update().filter(device_hash=device_hash).first()
                )
                if installation is None:
                    installation = Installation.objects.create(device_hash=device_hash, **fields)
                else:
                    for name, value in fields.items():
                        setattr(installation, name, value)
                    installation.save(update_fields=list(fields))
            return installation, token
        except IntegrityError:  # concurrent first registration of the same device
            continue
    raise APIError()


class InstallationsView(APIView):
    authentication_classes: list = []
    permission_classes = [AllowAny]

    def post(self, request):
        token, request_hash, device_hash, app_version = _parse(request.data)
        ratelimit.hit(
            "install_ip",
            ip_key(request),
            limit=settings.RATE_INSTALLATIONS_PER_IP_HOUR,
            window_seconds=ratelimit.HOUR,
        )
        ratelimit.hit(
            "install_device",
            device_hash[:32],
            limit=settings.RATE_INSTALLATIONS_PER_DEVICE_DAY,
            window_seconds=ratelimit.DAY,
        )
        try:
            integrity.verify(token, request_hash)
        except integrity.IntegrityFailed as exc:
            raise IntegrityFailedError() from exc
        except integrity.IntegrityUnavailable as exc:
            raise IntegrityUnavailableError() from exc
        installation, bearer = register(device_hash, app_version)
        logger.info("Installation registered", extra={"event": "installation_registered"})
        return Response({"installation_id": str(installation.id), "token": bearer}, status=201)
