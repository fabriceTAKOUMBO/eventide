"""Entitlements (contract § 6): plan, Premium, voice mode, computed from verified purchases.

Owner of purchases, credits and the monthly cost: the Google account when the installation is
linked (contract § 5), otherwise the installation itself.
"""

from __future__ import annotations

from dataclasses import dataclass
from datetime import UTC, date, datetime

from django.conf import settings
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

    @property
    def voice_mode(self) -> str:
        if not settings.VOICE_ENABLED:
            return "none"
        return {"free": "trial", "monthly": "included", "annual": "included"}.get(
            self.plan, "credits"
        )


def current_plan(owner: Owner) -> Plan:
    """An entitled subscription wins (voice included); otherwise lifetime; otherwise free."""
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


def trial_remaining(installation: Installation, account: Account | None) -> int:
    used = installation.trial_used
    if account is not None:
        used = max(used, account.trial_used)
    return max(0, settings.VOICE_TRIAL_REQUESTS - used)


def credits_of(owner: Owner) -> int:
    holder = owner.account if owner.account is not None else owner.installation
    return holder.credits


def month_start(today: date | None = None) -> date:
    today = today or timezone.now().astimezone(UTC).date()
    return today.replace(day=1)


def iso(value: datetime | None) -> str | None:
    if value is None:
        return None
    return value.astimezone(UTC).isoformat().replace("+00:00", "Z")


def voice_body(owner: Owner, plan: Plan) -> dict:
    from apps.voice.quota import monthly_cap_reached

    installation = Installation.objects.select_related("account").get(pk=owner.installation.pk)
    account = installation.account
    mode = plan.voice_mode
    return {
        "mode": mode,
        "trial_remaining": trial_remaining(installation, account),
        "credits_remaining": (account or installation).credits,
        "monthly_cap_reached": mode == "included" and monthly_cap_reached(owner),
    }


def entitlements_body(installation: Installation) -> dict:
    owner = owner_of(installation)
    plan = current_plan(owner)
    return {
        "plan": plan.plan,
        "premium": plan.premium,
        "expires_at": iso(plan.expires_at),
        "auto_renewing": plan.auto_renewing,
        "voice": voice_body(owner, plan),
    }
