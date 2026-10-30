"""Dashboard sign-in (contract § 14): Google ID token, verified e-mail in ``ADMIN_EMAILS``.

The address is never stored nor logged: the session keeps its SHA-256 only, checked against
the current ``ADMIN_EMAILS`` at every request (removing an address cuts access at once), and
the administrator's ``Account`` (Google ``sub``, the same account as in the app).
"""

from __future__ import annotations

import functools
import hashlib
from collections.abc import Callable
from typing import Any

from django.conf import settings
from django.http import HttpRequest, HttpResponse, HttpResponseRedirect, JsonResponse
from django.middleware.csrf import rotate_token

from apps.accounts import google_token
from apps.accounts.models import Account

SESSION_ACCOUNT = "admin_account"
SESSION_EMAIL_HASH = "admin_email_sha256"
LOGIN_URL = "/tableau/connexion"
# Value of a secret not filled in yet (Terraform creates the secrets with it).
PLACEHOLDER = "A_REMPLACER"


class AccessDenied(Exception):
    pass


def email_hash(email: str) -> str:
    return hashlib.sha256(email.strip().lower().encode("utf-8")).hexdigest()


def admin_hashes() -> frozenset[str]:
    """Hashes of the configured administrators. The secret's placeholder (``A_REMPLACER``)
    or any value that is not an address means no administrator."""
    return frozenset(
        email_hash(e) for e in settings.ADMIN_EMAILS if "@" in e and e.upper() != PLACEHOLDER
    )


def configured() -> bool:
    client = settings.GOOGLE_WEB_CLIENT_ID
    return bool(client and client.upper() != PLACEHOLDER and admin_hashes())


def verify_admin_token(token: str) -> tuple[str, str]:
    """(Google ``sub``, SHA-256 of the address) of an administrator's ID token; ``AccessDenied``
    otherwise. ``google_token.GoogleUnavailable`` when Google's keys cannot be fetched."""
    if not admin_hashes():
        raise AccessDenied()
    try:
        claims = google_token.verify_claims(token)
    except google_token.InvalidGoogleToken as exc:
        raise AccessDenied() from exc
    if claims.get("aud") not in settings.GOOGLE_OAUTH_CLIENT_IDS:
        raise AccessDenied()
    if claims.get("email_verified") not in (True, "true"):
        raise AccessDenied()
    email = claims.get("email")
    sub = claims.get("sub")
    if not isinstance(email, str) or not isinstance(sub, str) or not 0 < len(sub) <= 255:
        raise AccessDenied()
    digest = email_hash(email)
    del email, claims  # the address goes no further
    if digest not in admin_hashes():
        raise AccessDenied()
    return sub, digest


def sign_in(request: HttpRequest, token: str) -> Account:
    sub, digest = verify_admin_token(token)
    account, _ = Account.objects.get_or_create(google_sub=sub)
    request.session.cycle_key()
    request.session[SESSION_ACCOUNT] = str(account.pk)
    request.session[SESSION_EMAIL_HASH] = digest
    rotate_token(request)
    return account


def current_admin(request: HttpRequest) -> Account | None:
    """The signed-in administrator, re-checked against ``ADMIN_EMAILS`` (one session read and
    one account read); a stale session is flushed."""
    session = request.session
    account_id = session.get(SESSION_ACCOUNT)
    digest = session.get(SESSION_EMAIL_HASH)
    if not account_id or not digest:
        return None
    account = None
    if digest in admin_hashes():
        account = Account.objects.filter(pk=account_id).first()
    if account is None:
        session.flush()
    return account


def admin_required(*, json: bool = False) -> Callable:
    """Views of the dashboard: the signed-in administrator in ``request.admin``; otherwise a
    redirect to the sign-in page (pages and forms) or 403 (JSON endpoints)."""

    def decorator(view: Callable[..., HttpResponse]) -> Callable[..., HttpResponse]:
        @functools.wraps(view)
        def wrapper(request: HttpRequest, *args: Any, **kwargs: Any) -> HttpResponse:
            account = current_admin(request)
            if account is None:
                if json:
                    return JsonResponse(
                        {"error": "forbidden", "detail": "Session expirée : reconnectez-vous."},
                        status=403,
                    )
                return HttpResponseRedirect(LOGIN_URL)
            request.admin = account
            return view(request, *args, **kwargs)

        return wrapper

    return decorator
