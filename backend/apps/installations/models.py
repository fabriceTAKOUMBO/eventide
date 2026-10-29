"""App installation, identified by the device hash and authenticated by an opaque token."""

import uuid

from django.db import models


class Installation(models.Model):
    id = models.UUIDField(primary_key=True, default=uuid.uuid4, editable=False)
    # hex SHA-256(ANDROID_ID + app salt), computed on the phone (contract § 4). One row per
    # device: a reinstall finds the same row (same purchases and linked account).
    device_hash = models.CharField(max_length=64, unique=True)
    # SHA-256 of the bearer token (the token itself is never stored).
    token_hash = models.CharField(max_length=64, unique=True)
    token_issued_at = models.DateTimeField()
    app_version = models.CharField(max_length=32)
    account = models.ForeignKey(
        "accounts.Account",
        null=True,
        blank=True,
        on_delete=models.SET_NULL,
        related_name="installations",
    )
    created_at = models.DateTimeField(auto_now_add=True)
    last_seen_at = models.DateTimeField()

    # DRF treats the authenticated installation as ``request.user``.
    is_authenticated = True
    is_anonymous = False

    def __str__(self) -> str:
        return f"Installation {self.id}"
