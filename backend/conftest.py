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


@pytest.fixture(autouse=True)
def aws_stubs(monkeypatch):
    """Every AWS client is wrapped in an active botocore ``Stubber``: a call without a queued
    response raises instead of reaching AWS. ``aws_stubs("ecs")`` returns the stubber of that
    client (created on first use)."""
    from botocore.stub import Stubber

    from apps.publishing import aws

    stubbers: dict[str, Stubber] = {}
    real_make = aws._make

    def make(service):
        client = real_make(service)
        stubber = Stubber(client)
        stubber.activate()
        stubbers[service] = stubber
        return client

    monkeypatch.setattr(aws, "_make", make)
    aws.reset_clients()

    def get(service):
        aws.client(service)
        return stubbers[service]

    yield get
    aws.reset_clients()


@pytest.fixture(autouse=True)
def _fresh_published_catalog():
    """The published catalog is cached per process by revision; test transactions roll the
    revision back, so each test starts from an empty cache."""
    from apps.publishing.catalog import reset_cache_for_tests

    reset_cache_for_tests()
    yield
    reset_cache_for_tests()


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
