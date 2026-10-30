"""``POST /v1/content/urls`` (contract § 8): signed CloudFront URLs for catalog content.

Keys are checked against the published catalog (contract § 13): a published element's files
carry its current media revision (``<id>.v<media_rev>.<ext>``) and only that one; a withdrawn
element is unknown; base items have no revision.
"""

from __future__ import annotations

import re
import time
from datetime import UTC, datetime

from django.conf import settings
from rest_framework.response import Response
from rest_framework.views import APIView

from apps.core import ratelimit
from apps.core.catalog import Catalog
from apps.core.errors import APIError, InvalidRequest
from apps.entitlements.services import current_plan, iso, owner_of
from apps.publishing.catalog import current_catalog

from . import signing

MAX_KEYS = 30
# Matched with ``fullmatch``: ``$`` alone would also accept a trailing newline.
KEY_RE = re.compile(
    r"(audio/sons|audio/musiques|images/paysages|videos/paysages)/([a-z0-9-]{1,64})"
    r"(?:\.v([1-9][0-9]{0,8}))?\.(ogg|jpg|mp4)"
)
# (prefix, extension) -> catalog section; any other pair is refused. A landscape's still image
# and its video are both gated by the landscape's own ``gratuit`` flag; a variant of an event
# sound (``audio/sons/tonnerre-coup-01.ogg``, contract § 11) by its sound's.
LAYOUT = {
    ("audio/sons", "ogg"): "sons",
    ("audio/musiques", "ogg"): "musiques",
    ("images/paysages", "jpg"): "paysages",
    ("videos/paysages", "mp4"): "paysages",
}


class PremiumRequired(APIError):
    status = 403
    code = "premium_required"
    detail = "Contenu réservé à Premium."


class ContentUnavailable(APIError):
    status = 503
    code = "content_unavailable"
    detail = "Contenu momentanément indisponible."


def parse_keys(data: object, catalog: Catalog) -> list[tuple[str, str, str]]:
    if not isinstance(data, dict) or not isinstance(data.get("keys"), list):
        raise InvalidRequest()
    keys = data["keys"]
    if not 1 <= len(keys) <= MAX_KEYS or len(set(map(str, keys))) != len(keys):
        raise InvalidRequest()
    parsed = []
    for key in keys:
        match = KEY_RE.fullmatch(key) if isinstance(key, str) else None
        section = LAYOUT.get((match.group(1), match.group(4))) if match else None
        if section is None:
            raise InvalidRequest()
        file_id = match.group(2)
        item = catalog.sound_of_file(file_id) if section == "sons" else file_id
        if item is None or not catalog.has(section, item):
            raise InvalidRequest()
        # A published element: its current media revision only; a base item: no revision.
        given = int(match.group(3)) if match.group(3) else None
        if given != catalog.media_rev(section, file_id):
            raise InvalidRequest()
        parsed.append((key, section, item))
    return parsed


class ContentUrlsView(APIView):
    def post(self, request):
        catalog = current_catalog()
        keys = parse_keys(request.data, catalog)
        ratelimit.hit(
            "content",
            str(request.user.pk),
            limit=settings.RATE_CONTENT_PER_HOUR,
            window_seconds=ratelimit.HOUR,
        )
        premium_keys = any(not catalog.is_free(section, item) for _, section, item in keys)
        if premium_keys and not current_plan(owner_of(request.user)).premium:
            raise PremiumRequired()
        expires = int(time.time()) + settings.CONTENT_URL_TTL_SECONDS
        try:
            urls = {
                key: signing.sign(f"{settings.CONTENT_BASE_URL}/{key}", expires)
                for key, _, _ in keys
            }
        except signing.SigningNotConfigured as exc:
            raise ContentUnavailable() from exc
        return Response({"urls": urls, "expires_at": iso(datetime.fromtimestamp(expires, UTC))})
