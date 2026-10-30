"""``GET /v1/catalog`` (contract § 13): the published catalog, with its revision as ETag."""

from __future__ import annotations

from django.conf import settings
from django.http import HttpResponse
from django.utils.http import parse_etags
from rest_framework.views import APIView

from apps.core import ratelimit

from .catalog import published_catalog

CACHE_CONTROL = "private, no-cache"


class CatalogView(APIView):
    def get(self, request):
        ratelimit.hit(
            "catalog",
            str(request.user.pk),
            limit=settings.RATE_CATALOG_PER_HOUR,
            window_seconds=ratelimit.HOUR,
        )
        published = published_catalog()
        etag = published.etag
        headers = {"ETag": etag, "Cache-Control": CACHE_CONTROL}
        wanted = parse_etags(request.headers.get("If-None-Match", ""))
        # Weak or strong comparison alike (the revision is the whole representation).
        if "*" in wanted or etag in {tag.removeprefix("W/") for tag in wanted}:
            return HttpResponse(status=304, headers=headers)
        return HttpResponse(
            published.body, content_type="application/json; charset=utf-8", headers=headers
        )
