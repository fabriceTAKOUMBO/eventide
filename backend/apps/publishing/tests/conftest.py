"""Fixtures of the publishing tests: a signed-in administrator, published elements."""

from __future__ import annotations

from typing import Any

import pytest
from django.db import transaction
from django.test import Client
from django.utils import timezone

from apps.accounts.models import Account
from apps.publishing import admin_auth, services
from apps.publishing.models import PublishedItem

ADMIN_EMAIL = "admin@eventide.test"
VERIFY = "google.oauth2.id_token.verify_oauth2_token"
WEB_CLIENT = "client-1.apps.googleusercontent.com"


def claims(**overrides: Any) -> dict[str, Any]:
    base = {
        "iss": "https://accounts.google.com",
        "aud": WEB_CLIENT,
        "sub": "google-admin-1",
        "email": "Admin@Eventide.test",
        "email_verified": True,
    }
    base.update(overrides)
    return base


def sign_in(client: Client, account: Account, email: str = ADMIN_EMAIL) -> Client:
    session = client.session
    session[admin_auth.SESSION_ACCOUNT] = str(account.pk)
    session[admin_auth.SESSION_EMAIL_HASH] = admin_auth.email_hash(email)
    session.save()
    return client


@pytest.fixture
def admin_account(db) -> Account:
    return Account.objects.create(google_sub="google-admin-1")


@pytest.fixture
def admin_client(admin_account) -> Client:
    return sign_in(Client(), admin_account)


def publish_item(
    kind: str = PublishedItem.Kind.SON,
    item_id: str = "vent-doux",
    *,
    nom: str = "Vent doux",
    gratuit: bool = True,
    media_rev: int = 1,
    has_ambiance: bool = False,
    en_catalogue: bool = True,
    **fields: Any,
) -> PublishedItem:
    """An element already processed and (by default) in the published catalog."""
    with transaction.atomic():
        item = PublishedItem.objects.create(
            kind=kind,
            item_id=item_id,
            nom=nom,
            gratuit=gratuit,
            media_rev=media_rev,
            pending_rev=media_rev,
            has_ambiance=has_ambiance,
            en_catalogue=en_catalogue,
            state=PublishedItem.State.PUBLIE if en_catalogue else PublishedItem.State.RETIRE,
            published_at=timezone.now(),
            **fields,
        )
        services.bump_revision()
    return item
