"""Administration dashboard (contract § 14), server-rendered pages under ``/tableau/``.

Every response: a CSP that only adds Google Identity Services (sign-in page) or the content
bucket's upload address and the content CDN (other pages) to the site's own origin,
``Cache-Control: no-store``, ``X-Frame-Options: DENY``. Every form and every request that
changes something carries the CSRF token. No inline script: static files only.
"""

from __future__ import annotations

import functools
import math
import time
from collections.abc import Callable
from typing import Any
from urllib.parse import urlsplit

from django.conf import settings
from django.http import (
    Http404,
    HttpRequest,
    HttpResponse,
    HttpResponseRedirect,
    JsonResponse,
)
from django.shortcuts import render
from django.views.decorators.http import require_GET, require_http_methods, require_POST

from apps.accounts import google_token
from apps.content import signing
from apps.core import ratelimit
from apps.core.catalog import get_catalog
from apps.core.clientip import ip_key
from apps.core.errors import RateLimited

from . import admin_auth, aws, processing, services, stats
from .catalog import current_revision, media_keys
from .forms import EXTRA_MUSIC, EXTRA_SOUNDS, EditForm, NewElementForm
from .models import AdminLogEntry, PublishedItem

GIS = "https://accounts.google.com/gsi/"
LOGIN_WINDOW_SECONDS = 15 * 60
CREDENTIAL_MAX = 8192
POLL_STATES = (PublishedItem.State.TRAITEMENT,)
MESSAGES = {
    "cree": ("ok", "Élément créé : envoyez maintenant son fichier."),
    "publie": ("ok", "Publié : l'application le reçoit à sa prochaine mise à jour du catalogue."),
    "retire": ("ok", "Retiré du catalogue. Ses fichiers restent : il peut être publié de nouveau."),
    "modifie": ("ok", "Modifications enregistrées."),
    "refus": ("erreur", "Action impossible dans l'état actuel de l'élément."),
}

State = PublishedItem.State
Kind = PublishedItem.Kind


def _origin(url: str) -> str:
    parts = urlsplit(url)
    return f"{parts.scheme}://{parts.netloc}" if parts.scheme and parts.netloc else ""


def csp(*, login: bool) -> str:
    directives: dict[str, list[str]] = {
        "default-src": ["'none'"],
        "script-src": ["'self'"],
        "style-src": ["'self'"],
        "img-src": ["'self'"],
        "connect-src": ["'self'"],
        "form-action": ["'self'"],
        "base-uri": ["'none'"],
        "frame-ancestors": ["'none'"],
    }
    if login:
        # Google Identity Services: its script, its button frame (and the style and status
        # requests its button makes, per Google's CSP guide).
        directives["script-src"].append(f"{GIS}client")
        directives["frame-src"] = [GIS]
        directives["connect-src"].append(GIS)
        directives["style-src"].append(f"{GIS}style")
    else:
        upload = aws.upload_origin()
        if upload:
            directives["connect-src"].append(upload)
            directives["form-action"].append(upload)
        cdn = _origin(settings.CONTENT_BASE_URL)
        if cdn:
            directives["img-src"].append(cdn)
            directives["media-src"] = [cdn]
    return "; ".join(f"{name} {' '.join(values)}" for name, values in directives.items())


def secure(response: HttpResponse, *, login: bool = False) -> HttpResponse:
    response["Content-Security-Policy"] = csp(login=login)
    response["Cache-Control"] = "no-store"
    response["X-Frame-Options"] = "DENY"
    # Same-origin form posts must carry their Origin (CSRF); the sign-in page also gives its
    # origin to Google, which checks it, and keeps its popup.
    response["Referrer-Policy"] = "strict-origin-when-cross-origin" if login else "same-origin"
    if login:
        response["Cross-Origin-Opener-Policy"] = "same-origin-allow-popups"
    return response


def dashboard(*, login: bool = False) -> Callable:
    def decorator(view: Callable[..., HttpResponse]) -> Callable[..., HttpResponse]:
        @functools.wraps(view)
        def wrapper(request: HttpRequest, *args: Any, **kwargs: Any) -> HttpResponse:
            return secure(view(request, *args, **kwargs), login=login)

        return wrapper

    return decorator


def _page(request: HttpRequest, template: str, context: dict[str, Any], status: int = 200):
    admin = getattr(request, "admin", None)
    code = request.GET.get("message", "")
    message = None
    if code in MESSAGES:
        kind, text = MESSAGES[code]
        message = {"kind": kind, "text": text}
    return render(
        request,
        f"tableau/{template}",
        {"admin": admin, "message": message, **context},
        status=status,
    )


def _redirect(item: PublishedItem, message: str) -> HttpResponse:
    return HttpResponseRedirect(f"/tableau/elements/{item.pk}?message={message}")


def _item(pk: Any) -> PublishedItem:
    item = PublishedItem.objects.filter(pk=pk).first()
    if item is None:
        raise Http404
    return item


def _int_page(request: HttpRequest) -> int:
    try:
        return max(1, int(request.GET.get("page", "1")))
    except ValueError:
        return 1


# ----------------------------------------------------------------------------
# Sign-in
# ----------------------------------------------------------------------------


@dashboard(login=True)
@require_http_methods(["GET", "POST"])
def login(request: HttpRequest) -> HttpResponse:
    if request.method == "GET":
        if admin_auth.current_admin(request) is not None:
            return HttpResponseRedirect("/tableau/")
        return _login_page(request)
    try:
        ratelimit.hit(
            "admin_login",
            ip_key(request),
            limit=settings.RATE_ADMIN_LOGIN_PER_15_MIN,
            window_seconds=LOGIN_WINDOW_SECONDS,
        )
    except RateLimited as exc:
        response = _page(request, "refuse.html", {"trop": True}, status=429)
        response["Retry-After"] = exc.headers["Retry-After"]
        return response
    token = request.POST.get("credential", "")
    if not 1 <= len(token) <= CREDENTIAL_MAX:
        return _page(request, "refuse.html", {}, status=403)
    try:
        account = admin_auth.sign_in(request, token)
    except admin_auth.AccessDenied:
        return _page(request, "refuse.html", {}, status=403)
    except google_token.GoogleUnavailable:
        return _login_page(request, unavailable=True, status=503)
    services.log(account.pk, AdminLogEntry.Action.CONNEXION)
    return HttpResponseRedirect("/tableau/")


def _login_page(request: HttpRequest, *, unavailable: bool = False, status: int = 200):
    return _page(
        request,
        "connexion.html",
        {
            "client_id": settings.GOOGLE_WEB_CLIENT_ID,
            "configured": admin_auth.configured(),
            "unavailable": unavailable,
        },
        status=status,
    )


@dashboard()
@require_POST
def logout(request: HttpRequest) -> HttpResponse:
    account = admin_auth.current_admin(request)
    if account is not None:
        services.log(account.pk, AdminLogEntry.Action.DECONNEXION)
    request.session.flush()
    return HttpResponseRedirect(admin_auth.LOGIN_URL)


# ----------------------------------------------------------------------------
# Catalogue and elements
# ----------------------------------------------------------------------------


@dashboard()
@require_GET
@admin_auth.admin_required()
def catalogue(request: HttpRequest) -> HttpResponse:
    base = get_catalog()
    filmed = sum(1 for p in base.raw["paysages"] if p.get("rendu", "video") == "video")
    context = {
        "section": "catalogue",
        "elements": list(PublishedItem.objects.order_by("-created_at")[:500]),
        "revision": current_revision(),
        "base": {
            "filmes": filmed,
            "scenes": len(base.raw["paysages"]) - filmed,
            "sons": len(base.raw["sons"]),
            "musiques": len(base.raw["musiques"]),
        },
    }
    return _page(request, "catalogue.html", context)


@dashboard()
@require_http_methods(["GET", "POST"])
@admin_auth.admin_required()
def new_element(request: HttpRequest) -> HttpResponse:
    form = NewElementForm(request.POST or None)
    if request.method == "POST" and form.is_valid():
        item = services.create(form.values(), request.admin.pk)
        return _redirect(item, "cree")
    context = {
        "section": "catalogue",
        "form": form,
        "sons": [(form[f"son_{i}"], form[f"niveau_son_{i}"]) for i in range(1, EXTRA_SOUNDS + 1)],
        "musiques": [
            (form[f"musique_{i}"], form[f"niveau_musique_{i}"]) for i in range(1, EXTRA_MUSIC + 1)
        ],
    }
    return _page(request, "nouveau.html", context, status=400 if form.is_bound else 200)


def _preview(item: PublishedItem) -> dict[str, Any] | None:
    """Signed CDN addresses of the processed files: the pending ones (ready to publish), else
    the published ones."""
    if item.state == State.PRET and item.pending_rev:
        rev, ambiance, label = item.pending_rev, item.pending_has_ambiance, "à publier"
    elif item.media_rev:
        rev, ambiance, label = item.media_rev, item.has_ambiance, "en ligne"
    else:
        return None
    keys = media_keys(item.kind, item.item_id, rev, ambiance)
    expires = int(time.time()) + settings.CONTENT_URL_TTL_SECONDS
    try:
        urls = {
            name: signing.sign(f"{settings.CONTENT_BASE_URL}/{key}", expires)
            for name, key in keys.items()
        }
    except signing.SigningNotConfigured:
        return {"rev": rev, "label": label, "keys": keys, "urls": None}
    return {"rev": rev, "label": label, "keys": keys, "urls": urls}


def _actions(item: PublishedItem) -> dict[str, bool]:
    return {
        "publier": (item.state == State.PRET and item.pending_rev >= 1)
        or (item.state == State.RETIRE and item.media_rev >= 1),
        "retirer": item.en_catalogue,
        "envoyer": True,
    }


@dashboard()
@require_GET
@admin_auth.admin_required()
def element(request: HttpRequest, pk: Any) -> HttpResponse:
    item = services.expire_stale(_item(pk))
    accept = ",".join(f".{ext}" for ext in services.SOURCE_TYPES[item.kind])
    context = {
        "section": "catalogue",
        "item": item,
        "preview": _preview(item),
        "actions": _actions(item),
        "poll": item.state in POLL_STATES,
        "accept": accept,
        "max_mo": settings.UPLOAD_MAX_BYTES // 1_000_000,
        "upload_ready": bool(settings.CONTENT_BUCKET),
        "mix": item.mix if item.kind == Kind.PAYSAGE else None,
    }
    return _page(request, "element.html", context)


@dashboard()
@require_GET
@admin_auth.admin_required(json=True)
def element_state(request: HttpRequest, pk: Any) -> HttpResponse:
    item = services.expire_stale(_item(pk))
    return JsonResponse({"etat": item.state, "detail": item.detail})


def _json_error(code: str, detail: str, status: int) -> JsonResponse:
    return JsonResponse({"error": code, "detail": detail}, status=status)


@dashboard()
@require_POST
@admin_auth.admin_required(json=True)
def upload_start(request: HttpRequest, pk: Any) -> HttpResponse:
    item = _item(pk)
    extension = request.POST.get("extension", "")[:8]
    try:
        form = services.start_upload(item.pk, extension, request.admin.pk)
    except services.Busy as exc:
        return _json_error("busy", str(exc), 409)
    except services.ActionRefused as exc:
        return _json_error("invalid_request", str(exc), 400)
    except aws.NotConfigured:
        return _json_error(
            "upload_unavailable", "L'envoi de fichiers n'est pas configuré sur ce serveur.", 503
        )
    return JsonResponse(form)


@dashboard()
@require_POST
@admin_auth.admin_required(json=True)
def upload_done(request: HttpRequest, pk: Any) -> HttpResponse:
    item = _item(pk)
    outcome = services.finish_upload(item.pk, request.POST.get("upload_id", ""))
    if outcome == services.BUSY:
        # One media task at a time: the source stays, the page launches it again later.
        return _json_error("busy", services.BUSY_DETAIL, 409)
    if outcome != services.STARTED:
        return _json_error("conflict", "Cet envoi n'est plus en cours.", 409)
    item.refresh_from_db()
    processing.start(item)
    item.refresh_from_db()
    return JsonResponse({"etat": item.state, "detail": item.detail})


@dashboard()
@require_POST
@admin_auth.admin_required()
def publish(request: HttpRequest, pk: Any) -> HttpResponse:
    item = _item(pk)
    try:
        services.publish(item.pk, request.admin.pk)
    except services.ActionRefused:
        return _redirect(item, "refus")
    return _redirect(item, "publie")


@dashboard()
@require_POST
@admin_auth.admin_required()
def withdraw(request: HttpRequest, pk: Any) -> HttpResponse:
    item = _item(pk)
    try:
        services.withdraw(item.pk, request.admin.pk)
    except services.ActionRefused:
        return _redirect(item, "refus")
    return _redirect(item, "retire")


@dashboard()
@require_http_methods(["GET", "POST"])
@admin_auth.admin_required()
def edit(request: HttpRequest, pk: Any) -> HttpResponse:
    item = _item(pk)
    initial = {
        "nom": item.nom,
        "gratuit": "gratuit" if item.gratuit else "premium",
        "alias": ", ".join(item.alias),
    }
    form = EditForm(request.POST or None, initial=initial)
    if request.method == "POST" and form.is_valid():
        services.edit(item.pk, form.values(), request.admin.pk)
        return _redirect(item, "modifie")
    status = 400 if form.is_bound else 200
    return _page(
        request, "modifier.html", {"section": "catalogue", "item": item, "form": form}, status
    )


# ----------------------------------------------------------------------------
# Users and journal (read only)
# ----------------------------------------------------------------------------


def _pages(page: int, total: int, size: int) -> dict[str, Any]:
    count = max(1, math.ceil(total / size))
    return {
        "page": page,
        "pages": count,
        "previous": page - 1 if page > 1 else None,
        "next": page + 1 if page < count else None,
    }


@dashboard()
@require_GET
@admin_auth.admin_required()
def users(request: HttpRequest) -> HttpResponse:
    page = _int_page(request)
    totals = stats.totals()
    context = {
        "section": "utilisateurs",
        "totals": totals,
        "rows": stats.page_rows(page),
        "pagination": _pages(page, totals.installations, stats.PAGE_SIZE),
    }
    return _page(request, "utilisateurs.html", context)


@dashboard()
@require_GET
@admin_auth.admin_required()
def journal(request: HttpRequest) -> HttpResponse:
    page = _int_page(request)
    size = 50
    total = AdminLogEntry.objects.count()
    offset = (page - 1) * size
    entries = list(
        AdminLogEntry.objects.order_by("-at", "-id").values(
            "at", "action", "account_id", "element_id", "element_label"
        )[offset : offset + size]
    )
    labels = dict(AdminLogEntry.Action.choices)
    rows = [
        {
            **e,
            "action_label": labels.get(e["action"], e["action"]),
            "compte": str(e["account_id"])[:8] if e["account_id"] else "compte supprimé",
            "vous": e["account_id"] == request.admin.pk,
        }
        for e in entries
    ]
    context = {"section": "journal", "rows": rows, "pagination": _pages(page, total, size)}
    return _page(request, "journal.html", context)


@dashboard()
def csrf_failure(request: HttpRequest, reason: str = "") -> HttpResponse:
    """CSRF refusal (the dashboard is the only part of the site that uses CSRF)."""
    return _page(request, "csrf.html", {}, status=403)
