"""Voice usage accounting (contract § 7). The phrase and the transcript are NEVER stored."""

import uuid

from django.db import models
from django.db.models import Q


class VoiceRequest(models.Model):
    """One counted request: its reservation, then its settlement or release."""

    class Source(models.TextChoices):
        MODEL = "model"
        LOCAL = "local"

    class Charge(models.TextChoices):
        TRIAL = "trial"
        CREDIT = "credit"
        CAP = "cap"  # monthly / annual subscriber: cost counted against the 2 EUR cap
        NONE = "none"

    class Status(models.TextChoices):
        RESERVED = "reserved"
        SETTLED = "settled"
        RELEASED = "released"

    id = models.UUIDField(primary_key=True, default=uuid.uuid4, editable=False)
    installation = models.ForeignKey(
        "installations.Installation", on_delete=models.CASCADE, related_name="voice_requests"
    )
    # Account charged (trial, credit, cap) when the installation was linked at that time.
    account = models.ForeignKey(
        "accounts.Account",
        null=True,
        blank=True,
        on_delete=models.CASCADE,
        related_name="voice_requests",
    )
    created_at = models.DateTimeField(auto_now_add=True)
    source = models.CharField(max_length=8, choices=Source.choices)
    charge = models.CharField(max_length=8, choices=Charge.choices)
    status = models.CharField(max_length=10, choices=Status.choices)
    month = models.DateField()
    day = models.DateField()
    reserved_micro_eur = models.BigIntegerField(default=0)
    cost_micro_eur = models.BigIntegerField(default=0)
    model = models.CharField(max_length=64, blank=True, default="")
    input_tokens = models.PositiveIntegerField(default=0)
    output_tokens = models.PositiveIntegerField(default=0)

    class Meta:
        indexes = [models.Index(fields=["status", "created_at"], name="voicerequest_status_idx")]

    def __str__(self) -> str:
        return f"VoiceRequest {self.id} ({self.status})"


class VoiceMonthlyUsage(models.Model):
    """Real cost of the model per subscriber and per calendar month (UTC), in micro-euros."""

    installation = models.ForeignKey(
        "installations.Installation",
        null=True,
        blank=True,
        on_delete=models.CASCADE,
        related_name="voice_usage",
    )
    account = models.ForeignKey(
        "accounts.Account",
        null=True,
        blank=True,
        on_delete=models.CASCADE,
        related_name="voice_usage",
    )
    month = models.DateField()
    spent_micro_eur = models.BigIntegerField(default=0)
    reserved_micro_eur = models.BigIntegerField(default=0)
    requests = models.PositiveIntegerField(default=0)

    class Meta:
        constraints = [
            models.CheckConstraint(
                condition=(Q(installation__isnull=True) & Q(account__isnull=False))
                | (Q(installation__isnull=False) & Q(account__isnull=True)),
                name="voiceusage_single_owner",
            ),
            models.UniqueConstraint(
                fields=["account", "month"],
                condition=Q(account__isnull=False),
                name="voiceusage_account_month",
            ),
            models.UniqueConstraint(
                fields=["installation", "month"],
                condition=Q(installation__isnull=False),
                name="voiceusage_installation_month",
            ),
            models.CheckConstraint(
                condition=Q(spent_micro_eur__gte=0) & Q(reserved_micro_eur__gte=0),
                name="voiceusage_amounts_not_negative",
            ),
        ]

    def __str__(self) -> str:
        return f"VoiceMonthlyUsage {self.month}"


class VoiceGlobalDay(models.Model):
    """Model cost of all users together per UTC day: global safety cap."""

    day = models.DateField(unique=True)
    spent_micro_eur = models.BigIntegerField(default=0)
    reserved_micro_eur = models.BigIntegerField(default=0)

    class Meta:
        constraints = [
            models.CheckConstraint(
                condition=Q(spent_micro_eur__gte=0) & Q(reserved_micro_eur__gte=0),
                name="voiceglobal_amounts_not_negative",
            )
        ]

    def __str__(self) -> str:
        return f"VoiceGlobalDay {self.day}"
