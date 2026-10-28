"""Shared pytest fixtures. No real Google or AWS endpoint is ever reached."""

from __future__ import annotations

import secrets
from datetime import timedelta

import pytest
import requests
import responses
from django.utils import timezone
from rest_framework.test import APIClient

from apps.core import google
from apps.core.catalog import get_catalog
from apps.entitlements.models import Purchase
from apps.installations.models import Installation
from apps.installations.tokens import hash_token, new_token


@pytest.fixture(autouse=True)
def _isolated_google_session():
    google.reset_session_for_tests()
    yield
    google.reset_session_for_tests()


@pytest.fixture
def catalog():
    return get_catalog()


def make_installation(*, account=None, device_hash: str | None = None, **fields):
    token = new_token()
    now = timezone.now()
    installation = Installation.objects.create(
        device_hash=device_hash or secrets.token_hex(32),
        token_hash=hash_token(token),
        token_issued_at=now,
        app_version="1.0.0",
        last_seen_at=now,
        account=account,
        **fields,
    )
    return installation, token


def client_for(token: str) -> APIClient:
    client = APIClient()
    client.credentials(HTTP_AUTHORIZATION=f"Bearer {token}")
    return client


def make_purchase(*, installation=None, account=None, **fields) -> Purchase:
    defaults = {
        "purchase_token": secrets.token_urlsafe(40),
        "product_id": "eventide_premium",
        "base_plan_id": "monthly",
        "kind": Purchase.Kind.SUBSCRIPTION,
        "state": Purchase.State.ACTIVE,
        "expires_at": timezone.now() + timedelta(days=30),
        "auto_renewing": True,
        "acknowledged": True,
        "last_verified_at": timezone.now(),
    }
    defaults.update(fields)
    return Purchase.objects.create(installation=installation, account=account, **defaults)


@pytest.fixture
def installation(db):
    return make_installation()


@pytest.fixture
def api(installation):
    return client_for(installation[1])


@pytest.fixture
def google_http(monkeypatch):
    """Google APIs behind the service account: plain session + ``responses`` mocks."""
    session = requests.Session()
    for target in ("apps.installations.integrity", "apps.entitlements.play"):
        monkeypatch.setattr(f"{target}.authorized_session", lambda: session)
    with responses.RequestsMock(assert_all_requests_are_fired=False) as mock:
        yield mock
