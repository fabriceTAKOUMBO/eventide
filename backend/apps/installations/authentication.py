"""``Authorization: Bearer <token>`` (contract § 2): the token of an installation."""

from __future__ import annotations

from datetime import timedelta

from django.utils import timezone
from rest_framework import authentication, exceptions

from .models import Installation
from .tokens import hash_token

LAST_SEEN_RESOLUTION = timedelta(hours=1)


class InstallationTokenAuthentication(authentication.BaseAuthentication):
    keyword = "Bearer"

    def authenticate(self, request):
        header = authentication.get_authorization_header(request).split()
        if not header:
            return None
        if header[0].lower() != b"bearer" or len(header) != 2:
            raise exceptions.AuthenticationFailed()
        try:
            token = header[1].decode("ascii")
        except UnicodeDecodeError as exc:
            raise exceptions.AuthenticationFailed() from exc
        if not 20 <= len(token) <= 128:
            raise exceptions.AuthenticationFailed()
        installation = (
            Installation.objects.select_related("account")
            .filter(token_hash=hash_token(token))
            .first()
        )
        if installation is None:
            raise exceptions.AuthenticationFailed()
        now = timezone.now()
        if now - installation.last_seen_at > LAST_SEEN_RESOLUTION:
            Installation.objects.filter(pk=installation.pk).update(last_seen_at=now)
            installation.last_seen_at = now
        return installation, None

    def authenticate_header(self, request):
        return 'Bearer realm="eventide"'
