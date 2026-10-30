"""Server-side verification of a Google ID token (``google-auth``): account linking (contract
§ 5) and the dashboard sign-in (contract § 14)."""

from __future__ import annotations

from typing import Any

from django.conf import settings


class InvalidGoogleToken(Exception):
    pass


class GoogleUnavailable(Exception):
    pass


def verify_claims(token: str) -> dict[str, Any]:
    """The claims of a valid ID token (signature, issuer, expiry, audience = one of our client
    IDs). The caller keeps only what it needs (never the e-mail address)."""
    from google.auth import exceptions as google_exceptions
    from google.auth.transport import requests as google_requests
    from google.oauth2 import id_token

    audiences = settings.GOOGLE_OAUTH_CLIENT_IDS
    if not audiences:
        raise GoogleUnavailable("GOOGLE_OAUTH_CLIENT_IDS is empty")
    try:
        claims = id_token.verify_oauth2_token(token, google_requests.Request(), audience=audiences)
    except google_exceptions.TransportError as exc:
        raise GoogleUnavailable() from exc
    except (ValueError, google_exceptions.GoogleAuthError) as exc:
        raise InvalidGoogleToken() from exc
    if not isinstance(claims, dict):
        raise InvalidGoogleToken()
    return claims


def verify(token: str) -> str:
    """The Google subject (``sub``) of a valid ID token issued for one of our client IDs."""
    claims = verify_claims(token)
    sub = claims.get("sub")
    if not isinstance(sub, str) or not sub or len(sub) > 255:
        raise InvalidGoogleToken()
    return sub
