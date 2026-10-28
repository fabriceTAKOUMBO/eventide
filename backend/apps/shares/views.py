"""``POST /v1/shares`` and ``GET /v1/shares/{code}`` (contract § 8)."""

from __future__ import annotations

import re
import secrets
import string

from django.conf import settings
from django.db import IntegrityError, transaction
from rest_framework.response import Response
from rest_framework.views import APIView

from apps.core import ratelimit
from apps.core.errors import APIError, InvalidRequest, NotFound

from .models import Share
from .scene import InvalidScene, normalise_scene

ALPHABET = string.digits + string.ascii_letters  # base62
CODE_RE = re.compile(r"^[0-9A-Za-z]{8}$")


def new_code() -> str:
    return "".join(secrets.choice(ALPHABET) for _ in range(8))


def share_url(code: str) -> str:
    return f"{settings.PUBLIC_WEB_BASE_URL}/m/{code}"


class SharesView(APIView):
    def post(self, request):
        data = request.data
        try:
            scene = normalise_scene(data.get("scene") if isinstance(data, dict) else None)
        except InvalidScene as exc:
            raise InvalidRequest("Scène invalide.") from exc
        ratelimit.hit(
            "shares",
            str(request.user.pk),
            limit=settings.RATE_SHARES_PER_DAY,
            window_seconds=ratelimit.DAY,
        )
        for _ in range(5):
            code = new_code()
            try:
                with transaction.atomic():
                    Share.objects.create(code=code, scene=scene, installation=request.user)
            except IntegrityError:
                continue
            return Response({"code": code, "url": share_url(code)}, status=201)
        raise APIError()  # pragma: no cover - 62^8 codes: five collisions in a row


class ShareDetailView(APIView):
    def get(self, request, code: str):
        if not CODE_RE.match(code):
            raise NotFound()
        share = Share.objects.filter(code=code).first()
        if share is None:
            raise NotFound()
        return Response({"scene": share.scene})
