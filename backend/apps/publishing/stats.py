"""Users page of the dashboard (contract § 14): read only, pseudonymous data only.

A fixed number of queries whatever the page: one aggregate for the totals, one grouped count
of the active Premium purchases, then for the 50 rows of the page one query for the rows, one
for their share counts and one for their purchases.
"""

from __future__ import annotations

from dataclasses import dataclass
from datetime import datetime, timedelta
from typing import Any

from django.db.models import Count, Q
from django.utils import timezone

from apps.entitlements.models import Purchase
from apps.installations.models import Installation
from apps.shares.models import Share

PAGE_SIZE = 50

PRODUCT_LABELS = {
    ("eventide_premium", "monthly"): "Abonnement mensuel",
    ("eventide_premium", "annual"): "Abonnement annuel",
    ("eventide_premium", ""): "Abonnement",
    ("eventide_lifetime", ""): "À vie",
}
STATE_LABELS = {
    "active": "actif",
    "canceled": "annulé (jusqu'à l'échéance)",
    "in_grace": "délai de grâce",
    "on_hold": "suspendu",
    "paused": "en pause",
    "pending": "paiement en attente",
    "expired": "expiré",
    "revoked": "remboursé",
    "replaced": "remplacé",
}


def entitled(now: datetime) -> Q:
    return Q(
        kind=Purchase.Kind.SUBSCRIPTION,
        state__in=Purchase.ENTITLED_SUBSCRIPTION_STATES,
        expires_at__gt=now,
    ) | Q(kind=Purchase.Kind.LIFETIME, state=Purchase.State.ACTIVE)


def product_label(product_id: str, base_plan_id: str) -> str:
    return PRODUCT_LABELS.get(
        (product_id, base_plan_id), PRODUCT_LABELS.get((product_id, ""), product_id)
    )


@dataclass(frozen=True)
class Totals:
    installations: int
    actives_7: int
    actives_30: int
    comptes: int
    premium: list[tuple[str, int]]


def totals(now: datetime | None = None) -> Totals:
    now = now or timezone.now()
    agg = Installation.objects.aggregate(
        total=Count("id"),
        actives_7=Count("id", filter=Q(last_seen_at__gte=now - timedelta(days=7))),
        actives_30=Count("id", filter=Q(last_seen_at__gte=now - timedelta(days=30))),
        comptes=Count("account", distinct=True),
    )
    premium: dict[str, int] = {}
    for row in (
        Purchase.objects.filter(entitled(now))
        .values("product_id", "base_plan_id")
        .annotate(n=Count("id"))
        .order_by()
    ):
        label = product_label(row["product_id"], row["base_plan_id"])
        premium[label] = premium.get(label, 0) + row["n"]
    return Totals(
        installations=agg["total"],
        actives_7=agg["actives_7"],
        actives_30=agg["actives_30"],
        comptes=agg["comptes"],
        premium=sorted(premium.items()),
    )


def _best_purchase(purchases: list[dict[str, Any]], now: datetime) -> dict[str, Any] | None:
    """The purchase that gives the rights (an entitled subscription, then lifetime), otherwise
    the most recent one."""
    if not purchases:
        return None

    def rank(p: dict[str, Any]) -> tuple:
        sub_ok = (
            p["kind"] == Purchase.Kind.SUBSCRIPTION
            and p["state"] in Purchase.ENTITLED_SUBSCRIPTION_STATES
            and p["expires_at"] is not None
            and p["expires_at"] > now
        )
        life_ok = p["kind"] == Purchase.Kind.LIFETIME and p["state"] == Purchase.State.ACTIVE
        return (sub_ok, life_ok, p["created_at"])

    best = max(purchases, key=rank)
    return {
        "produit": product_label(best["product_id"], best["base_plan_id"]),
        "etat": STATE_LABELS.get(best["state"], best["state"]),
        "echeance": best["expires_at"],
        "actif": rank(best)[0] or rank(best)[1],
    }


def page_rows(page: int, now: datetime | None = None) -> list[dict[str, Any]]:
    now = now or timezone.now()
    offset = (page - 1) * PAGE_SIZE
    rows = list(
        Installation.objects.order_by("-created_at", "-id").values(
            "id", "created_at", "last_seen_at", "app_version", "account_id"
        )[offset : offset + PAGE_SIZE]
    )
    if not rows:
        return []
    ids = [r["id"] for r in rows]
    accounts = {r["account_id"] for r in rows if r["account_id"]}
    shares = dict(
        Share.objects.filter(installation_id__in=ids)
        .values("installation_id")
        .annotate(n=Count("id"))
        .order_by()
        .values_list("installation_id", "n")
    )
    by_installation: dict[Any, list[dict[str, Any]]] = {}
    by_account: dict[Any, list[dict[str, Any]]] = {}
    for p in Purchase.objects.filter(
        Q(installation_id__in=ids) | Q(account_id__in=accounts)
    ).values(
        "installation_id",
        "account_id",
        "product_id",
        "base_plan_id",
        "kind",
        "state",
        "expires_at",
        "created_at",
    ):
        if p["account_id"]:
            by_account.setdefault(p["account_id"], []).append(p)
        else:
            by_installation.setdefault(p["installation_id"], []).append(p)
    out = []
    for r in rows:
        owned = by_account.get(r["account_id"], []) if r["account_id"] else []
        owned = owned or by_installation.get(r["id"], [])
        out.append(
            {
                "installation": str(r["id"])[:8],
                "creation": r["created_at"],
                "activite": r["last_seen_at"],
                "version": r["app_version"],
                "compte": r["account_id"] is not None,
                "premium": _best_purchase(owned, now),
                "partages": shares.get(r["id"], 0),
            }
        )
    return out
