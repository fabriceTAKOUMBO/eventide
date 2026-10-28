"""App installation, identified by the device hash and authenticated by an opaque token."""

import uuid

from django.db import models


class Installation(models.Model):
    id = models.UUIDField(primary_key=True, default=uuid.uuid4, editable=False)
    # hex SHA-256(ANDROID_ID + app salt), computed on the phone (contract § 4). One row per
    # device: a reinstall finds the same row, so it does not give back the free trial.
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
    # Voice trial requests used on this device.
    trial_used = models.PositiveSmallIntegerField(default=0)
    # Voice credits while the installation is not linked to an account.
    credits = models.IntegerField(default=0)
    created_at = models.DateTimeField(auto_now_add=True)
    last_seen_at = models.DateTimeField()

    class Meta:
        constraints = [
            models.CheckConstraint(
                condition=models.Q(credits__gte=0), name="installation_credits_not_negative"
            )
        ]

    # DRF treats the authenticated installation as ``request.user``.
    is_authenticated = True
    is_anonymous = False

    def __str__(self) -> str:
        return f"Installation {self.id}"
