"""Web pages served by the API on the domain host (contract § 9).

- ``/m/<code>``: landing page of a share (App Links open the app directly when installed);
- ``/s``: self-contained share link (scene in the URL fragment, read by a small script);
- ``/.well-known/assetlinks.json``: App Links verification (fingerprints from configuration);
- ``/confidentialite``: privacy policy (French).

Strict CSP: no inline script, static files only from this origin.
"""

from __future__ import annotations

from typing import Any

from django.conf import settings
from django.http import HttpRequest, HttpResponse, JsonResponse
from django.shortcuts import render
from django.views.decorators.cache import cache_control
from django.views.decorators.http import require_GET

from apps.core.catalog import SCENE_SECTIONS, get_catalog
from apps.shares.models import Share
from apps.shares.views import CODE_RE

CSP = (
    "default-src 'none'; script-src 'self'; style-src 'self'; img-src 'self'; "
    "base-uri 'none'; form-action 'none'; frame-ancestors 'none'"
)
MOMENT_NAMES = {"aube": "Aube", "jour": "Jour", "soir": "Soir", "nuit": "Nuit"}
LAYER_TITLES = {"sons": "Sons", "musique": "Musique", "decor": "Décor"}


def _secure(response: HttpResponse) -> HttpResponse:
    response["Content-Security-Policy"] = CSP
    return response


def _store_url() -> str:
    return f"https://play.google.com/store/apps/details?id={settings.PLAY_PACKAGE_NAME}"


def _common() -> dict[str, Any]:
    return {"store_url": _store_url(), "package": settings.PLAY_PACKAGE_NAME}


def describe_scene(scene: dict) -> dict:
    catalog = get_catalog()
    paysage = scene["paysage"]
    layers = []
    for key, section in SCENE_SECTIONS.items():
        items = [
            {
                "nom": catalog.name(section, item["id"]),
                "niveau": item["niveau"],
                "premium": not catalog.is_free(section, item["id"]),
            }
            for item in scene.get(key, [])
            if catalog.has(section, item.get("id"))
        ]
        if items:
            layers.append({"titre": LAYER_TITLES[key], "elements": items})
    return {
        "paysage": catalog.name("paysages", paysage),
        "paysage_premium": not catalog.is_free("paysages", paysage),
        "moment": MOMENT_NAMES.get(scene.get("moment", ""), ""),
        "couches": layers,
    }


@require_GET
@cache_control(public=True, max_age=300)
def share_page(request: HttpRequest, code: str) -> HttpResponse:
    share = Share.objects.filter(code=code).first() if CODE_RE.match(code) else None
    if share is None:
        return _secure(render(request, "web/introuvable.html", _common(), status=404))
    host = settings.PUBLIC_WEB_BASE_URL.split("://", 1)[-1]
    context = {
        **_common(),
        "mix": describe_scene(share.scene),
        "intent_url": (
            f"intent://{host}/m/{code}#Intent;scheme=https;package={settings.PLAY_PACKAGE_NAME};"
            f"S.browser_fallback_url={_store_url()};end"
        ),
    }
    return _secure(render(request, "web/partage.html", context))


def _names() -> dict:
    catalog = get_catalog()
    return {
        section: {
            i: {"nom": catalog.name(section, i), "gratuit": catalog.is_free(section, i)}
            for i in catalog.sections[section]
        }
        for section in ("paysages", "sons", "musiques", "decors")
    }


@require_GET
@cache_control(public=True, max_age=300)
def standalone_share_page(request: HttpRequest) -> HttpResponse:
    context = {**_common(), "catalogue": _names()}
    return _secure(render(request, "web/partage_autonome.html", context))


@require_GET
@cache_control(public=True, max_age=3600)
def assetlinks(request: HttpRequest) -> HttpResponse:
    if not settings.PLAY_PACKAGE_NAME or not settings.ANDROID_CERT_FINGERPRINTS:
        return JsonResponse({"error": "not_found", "detail": "Introuvable."}, status=404)
    statement = {
        "relation": ["delegate_permission/common.handle_all_urls"],
        "target": {
            "namespace": "android_app",
            "package_name": settings.PLAY_PACKAGE_NAME,
            "sha256_cert_fingerprints": settings.ANDROID_CERT_FINGERPRINTS,
        },
    }
    return JsonResponse([statement], safe=False)


@require_GET
@cache_control(public=True, max_age=3600)
def privacy(request: HttpRequest) -> HttpResponse:
    context = {
        **_common(),
        "publisher": settings.LEGAL_PUBLISHER_NAME or "[à compléter]",
        "contact_email": settings.LEGAL_CONTACT_EMAIL or "[à compléter]",
        "updated_on": settings.LEGAL_PRIVACY_UPDATED_ON,
    }
    return _secure(render(request, "web/confidentialite.html", context))
