"""Authorised HTTP session for Google APIs (service account, ``google-auth``).

The same service account (JSON in Secrets Manager) is used for the Play Developer API and the
Play Integrity API. Tests replace ``authorized_session`` with a plain session and mock the
endpoints with ``responses``: no real Google call is ever made.
"""

from __future__ import annotations

import json
import threading

import requests
from django.conf import settings

SCOPES = (
    "https://www.googleapis.com/auth/androidpublisher",
    "https://www.googleapis.com/auth/playintegrity",
)

_lock = threading.Lock()
_session: requests.Session | None = None


class GoogleNotConfigured(Exception):
    """No service account: the calling feature answers 503."""


def authorized_session() -> requests.Session:
    global _session
    if _session is not None:
        return _session
    with _lock:
        if _session is None:
            raw = settings.GOOGLE_PLAY_SERVICE_ACCOUNT_JSON
            if not raw:
                raise GoogleNotConfigured("GOOGLE_PLAY_SERVICE_ACCOUNT_JSON is empty")
            from google.auth.transport.requests import AuthorizedSession
            from google.oauth2 import service_account

            try:
                info = json.loads(raw)
                credentials = service_account.Credentials.from_service_account_info(
                    info, scopes=list(SCOPES)
                )
            except (ValueError, KeyError, TypeError) as exc:
                # Placeholder « A_REMPLACER » or a malformed key: the feature answers 503.
                raise GoogleNotConfigured("invalid GOOGLE_PLAY_SERVICE_ACCOUNT_JSON") from exc
            _session = AuthorizedSession(credentials)
    return _session


def reset_session_for_tests() -> None:
    global _session
    _session = None
