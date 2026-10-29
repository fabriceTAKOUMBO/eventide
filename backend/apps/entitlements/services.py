"""Entitlements (contract § 6): plan and Premium, computed from verified purchases.

Owner of purchases: the Google account when the installation is linked (contract § 5),
otherwise the installation itself.
"""

from __future__ import annotations

from dataclasses import dataclass
from datetime import UTC, datetime

from django.db.models import Q
from django.utils import timezone

from apps.accounts.models import Account
from apps.installations.models import Installation

from .models import Purchase


@dataclass(frozen=True)
class Owner:
    installation: Installation
    account: Account | None

    @property
    def filter(self) -> Q:
        if self.account is not None:
            return Q(account=self.account)
        return Q(installation=self.installation)

    @property
    def fields(self) -> dict:
        if self.account is not None:
            return {"account": self.account, "installation": None}
        return {"installation": self.installation, "account": None}

    def owns(self, purchase: Purchase) -> bool:
        if self.account is not None:
            return purchase.account_id == self.account.pk
        return purchase.installation_id == self.installation.pk


def owner_of(installation: Installation) -> Owner:
    return Owner(installation=installation, account=installation.account)


@dataclass(frozen=True)
class Plan:
    plan: str  # free | monthly | annual | lifetime
    expires_at: datetime | None
    auto_renewing: bool

    @property
    def premium(self) -> bool:
        return self.plan != "free"


def current_plan(owner: Owner) -> Plan:
    """An entitled subscription wins; otherwise lifetime; otherwise free."""
    now = timezone.now()
    purchases = Purchase.objects.filter(owner.filter)
    subscription = (
        purchases.filter(
            kind=Purchase.Kind.SUBSCRIPTION,
            state__in=Purchase.ENTITLED_SUBSCRIPTION_STATES,
            expires_at__gt=now,
        )
        .order_by("-expires_at")
        .first()
    )
    if subscription is not None:
        plan = "annual" if subscription.base_plan_id == "annual" else "monthly"
        return Plan(plan, subscription.expires_at, subscription.auto_renewing)
    if purchases.filter(kind=Purchase.Kind.LIFETIME, state=Purchase.State.ACTIVE).exists():
        return Plan("lifetime", None, False)
    return Plan("free", None, False)


def iso(value: datetime | None) -> str | None:
    if value is None:
        return None
    return value.astimezone(UTC).isoformat().replace("+00:00", "Z")


def entitlements_body(installation: Installation) -> dict:
    owner = owner_of(installation)
    plan = current_plan(owner)
    return {
        "plan": plan.plan,
        "premium": plan.premium,
        "expires_at": iso(plan.expires_at),
        "auto_renewing": plan.auto_renewing,
    }
