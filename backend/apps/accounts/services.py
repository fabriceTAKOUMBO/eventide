"""Account linking, export and deletion (contract § 5, RGPD)."""

from __future__ import annotations

import logging

from django.db import transaction
from django.db.models import Q

from apps.entitlements.models import Purchase
from apps.entitlements.services import iso
from apps.installations.models import Installation
from apps.shares.models import Share

from .models import Account

logger = logging.getLogger(__name__)


def link(installation: Installation, google_sub: str) -> Account:
    """Link the installation to the Google account; its rights move to it: purchases owned by
    the installation now belong to the account."""
    with transaction.atomic():
        locked = Installation.objects.select_for_update().get(pk=installation.pk)
        account, _ = Account.objects.get_or_create(google_sub=google_sub)
        account = Account.objects.select_for_update().get(pk=account.pk)
        if locked.account_id == account.pk:
            return account
        Purchase.objects.filter(installation=locked).update(installation=None, account=account)
        locked.account = account
        locked.save(update_fields=["account"])
    logger.info("Installation linked to an account", extra={"event": "account_linked"})
    installation.refresh_from_db()
    return Account.objects.get(pk=account.pk)


def _purchase_rows(q: Q) -> list[dict]:
    return [
        {
            "product_id": p.product_id,
            "base_plan_id": p.base_plan_id or None,
            "state": p.state,
            "order_id": p.order_id or None,
            "expires_at": iso(p.expires_at),
            "created_at": iso(p.created_at),
        }
        for p in Purchase.objects.filter(q).order_by("created_at")
    ]


def export(installation: Installation) -> dict:
    """Everything the server holds for this installation and its account (RGPD art. 15/20)."""
    installation = Installation.objects.select_related("account").get(pk=installation.pk)
    account = installation.account
    installations = [installation]
    if account is not None:
        installations = list(account.installations.all().order_by("created_at"))
    owners = Q(installation__in=installations) | (Q(account=account) if account else Q(pk__in=[]))
    return {
        "installations": [
            {
                "installation_id": str(i.id),
                "device_hash": i.device_hash,
                "app_version": i.app_version,
                "created_at": iso(i.created_at),
                "last_seen_at": iso(i.last_seen_at),
            }
            for i in installations
        ],
        "account": None
        if account is None
        else {
            "account_id": str(account.id),
            "google_sub": account.google_sub,
            "created_at": iso(account.created_at),
        },
        "purchases": _purchase_rows(owners),
        "shares": [
            {"code": s.code, "created_at": iso(s.created_at), "scene": s.scene}
            for s in Share.objects.filter(installation__in=installations).order_by("created_at")
        ],
        "note": "Les achats restent enregistrés chez Google Play.",
    }


def delete(installation: Installation) -> None:
    """Delete the installation and, when linked, the account and every installation linked to
    it; cascades remove purchases and shares (contract § 5).
    Purchases remain at Google Play: posting the token again re-attaches them."""
    with transaction.atomic():
        locked = Installation.objects.select_for_update().get(pk=installation.pk)
        account_id = locked.account_id
        if account_id is not None:
            Installation.objects.filter(account_id=account_id).delete()
            Account.objects.filter(pk=account_id).delete()
        else:
            locked.delete()
    logger.info("Account data deleted", extra={"event": "account_deleted"})
