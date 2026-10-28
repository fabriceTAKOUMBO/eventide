"""Shared mixes (contract § 8): a normalised scene under a short code, no personal data."""

from django.db import models


class Share(models.Model):
    code = models.CharField(max_length=8, unique=True)
    scene = models.JSONField()
    # Creator, only for the RGPD export and deletion of « partages créés » (contract § 5).
    installation = models.ForeignKey(
        "installations.Installation", on_delete=models.CASCADE, related_name="shares"
    )
    created_at = models.DateTimeField(auto_now_add=True)

    def __str__(self) -> str:
        return f"Share {self.code}"
