"""Optional Google account (contract § 5): rights follow it once linked."""

import uuid

from django.db import models


class Account(models.Model):
    id = models.UUIDField(primary_key=True, default=uuid.uuid4, editable=False)
    # Stable Google subject identifier (``sub`` of the ID token). No e-mail, no name.
    google_sub = models.CharField(max_length=255, unique=True)
    created_at = models.DateTimeField(auto_now_add=True)

    def __str__(self) -> str:
        return f"Account {self.id}"
