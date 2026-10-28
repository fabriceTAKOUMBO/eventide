"""Optional Google account (contract § 5): rights and counters follow it once linked."""

import uuid

from django.db import models


class Account(models.Model):
    id = models.UUIDField(primary_key=True, default=uuid.uuid4, editable=False)
    # Stable Google subject identifier (``sub`` of the ID token). No e-mail, no name.
    google_sub = models.CharField(max_length=255, unique=True)
    created_at = models.DateTimeField(auto_now_add=True)
    # Voice trial requests used by this account (any device), contract § 4 and § 7.
    trial_used = models.PositiveSmallIntegerField(default=0)
    # Voice credits (consumable eventide_credits_50), one per request.
    credits = models.IntegerField(default=0)

    class Meta:
        constraints = [
            models.CheckConstraint(
                condition=models.Q(credits__gte=0), name="account_credits_not_negative"
            )
        ]

    def __str__(self) -> str:
        return f"Account {self.id}"
