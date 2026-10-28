"""Google Play purchases verified by the server (contract § 6)."""

import uuid

from django.db import models
from django.db.models import Q


class Purchase(models.Model):
    class Kind(models.TextChoices):
        SUBSCRIPTION = "subscription"
        LIFETIME = "lifetime"
        CREDITS = "credits"

    class State(models.TextChoices):
        ACTIVE = "active"  # paid and entitled (subscription: until expires_at)
        CANCELED = "canceled"  # subscription canceled, still entitled until expires_at
        IN_GRACE = "in_grace"  # payment issue, still entitled
        ON_HOLD = "on_hold"
        PAUSED = "paused"
        PENDING = "pending"  # payment not completed yet
        EXPIRED = "expired"
        REVOKED = "revoked"  # refunded or voided
        REPLACED = "replaced"  # superseded by an upgrade/downgrade (linkedPurchaseToken)

    ENTITLED_SUBSCRIPTION_STATES = (State.ACTIVE, State.CANCELED, State.IN_GRACE)

    id = models.UUIDField(primary_key=True, default=uuid.uuid4, editable=False)
    # The token is needed to query Google again (RTDN, finalisation): kept, never logged.
    purchase_token = models.TextField(unique=True)
    product_id = models.CharField(max_length=64)
    base_plan_id = models.CharField(max_length=32, blank=True, default="")
    kind = models.CharField(max_length=16, choices=Kind.choices)
    state = models.CharField(max_length=16, choices=State.choices)
    order_id = models.CharField(max_length=64, blank=True, default="")
    expires_at = models.DateTimeField(null=True, blank=True)
    auto_renewing = models.BooleanField(default=False)
    acknowledged = models.BooleanField(default=False)
    consumed = models.BooleanField(default=False)
    credits_granted = models.PositiveIntegerField(default=0)
    # Owner: the account when the installation is linked, otherwise the installation.
    installation = models.ForeignKey(
        "installations.Installation",
        null=True,
        blank=True,
        on_delete=models.CASCADE,
        related_name="purchases",
    )
    account = models.ForeignKey(
        "accounts.Account",
        null=True,
        blank=True,
        on_delete=models.CASCADE,
        related_name="purchases",
    )
    created_at = models.DateTimeField(auto_now_add=True)
    updated_at = models.DateTimeField(auto_now=True)
    last_verified_at = models.DateTimeField()

    class Meta:
        constraints = [
            models.CheckConstraint(
                condition=(Q(installation__isnull=True) & Q(account__isnull=False))
                | (Q(installation__isnull=False) & Q(account__isnull=True)),
                name="purchase_single_owner",
            )
        ]
        indexes = [models.Index(fields=["kind", "state"], name="purchase_kind_state_idx")]

    def __str__(self) -> str:
        return f"{self.product_id} ({self.state})"
