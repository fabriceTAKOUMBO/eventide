from unittest import mock

import pytest
from google.auth import exceptions as google_exceptions

from apps.accounts.models import Account
from apps.entitlements.models import Purchase
from apps.installations.models import Installation
from apps.shares.models import Share
from conftest import client_for, make_installation, make_purchase

VERIFY = "google.oauth2.id_token.verify_oauth2_token"
SCENE = {
    "version": 1,
    "paysage": "cascade-foret",
    "moment": "jour",
    "sons": [],
    "musique": [],
    "decor": [],
}


def link(client, sub="google-sub-1"):
    with mock.patch(VERIFY, return_value={"sub": sub, "aud": "client-1"}) as verify:
        response = client.post(
            "/v1/account/google", {"id_token": "header.payload.sig"}, format="json"
        )
    return response, verify


@pytest.mark.django_db
def test_link_creates_the_account_and_checks_the_audience(api, installation):
    inst, _ = installation
    response, verify = link(api)
    assert response.status_code == 200
    body = response.json()
    assert body["linked"] is True
    account = Account.objects.get(pk=body["account_id"])
    assert account.google_sub == "google-sub-1"
    inst.refresh_from_db()
    assert inst.account_id == account.pk
    assert verify.call_args.kwargs["audience"] == ["client-1.apps.googleusercontent.com"]
    # Linking again is a no-op.
    again, _ = link(api)
    assert again.json()["account_id"] == body["account_id"]


@pytest.mark.django_db
def test_invalid_google_token_is_401(api):
    with mock.patch(VERIFY, side_effect=ValueError("Token expired")):
        response = api.post("/v1/account/google", {"id_token": "x.y.z"}, format="json")
    assert response.status_code == 401
    assert response.json() == {"error": "invalid_google_token", "detail": "Jeton Google invalide."}


@pytest.mark.django_db
def test_token_without_subject_is_401(api):
    with mock.patch(VERIFY, return_value={"aud": "client-1"}):
        response = api.post("/v1/account/google", {"id_token": "x.y.z"}, format="json")
    assert response.status_code == 401


@pytest.mark.django_db
def test_google_certificates_unreachable_is_503(api):
    with mock.patch(VERIFY, side_effect=google_exceptions.TransportError("down")):
        response = api.post("/v1/account/google", {"id_token": "x.y.z"}, format="json")
    assert response.status_code == 503
    assert response.json()["error"] == "google_unavailable"


@pytest.mark.django_db
def test_no_client_id_configured_is_503(api, settings):
    settings.GOOGLE_OAUTH_CLIENT_IDS = []
    response = api.post("/v1/account/google", {"id_token": "x.y.z"}, format="json")
    assert response.status_code == 503


@pytest.mark.django_db
@pytest.mark.parametrize("data", [{}, {"id_token": ""}, {"id_token": 5}, ["x"]])
def test_invalid_link_bodies_are_400(api, data):
    assert api.post("/v1/account/google", data, format="json").status_code == 400


@pytest.mark.django_db
def test_rights_follow_the_account():
    # Device A bought Premium, then links the account: the purchase moves to the account.
    inst_a, token_a = make_installation()
    make_purchase(installation=inst_a)
    link(client_for(token_a), sub="same-person")
    account = Account.objects.get(google_sub="same-person")
    assert Purchase.objects.get().account_id == account.pk
    # Device B, fresh: linking the same account gives Premium.
    _inst_b, token_b = make_installation()
    client_b = client_for(token_b)
    assert client_b.get("/v1/entitlements").json()["plan"] == "free"
    link(client_b, sub="same-person")
    assert client_b.get("/v1/entitlements").json()["plan"] == "monthly"


@pytest.mark.django_db
def test_export_contains_everything_but_no_token(installation):
    inst, token = installation
    client = client_for(token)
    link(client, sub="sub-export")
    make_purchase(account=Account.objects.get(), order_id="GPA.1")
    client.post("/v1/shares", {"scene": SCENE}, format="json")
    response = client.get("/v1/account/export")
    assert response.status_code == 200
    data = response.json()
    assert set(data) == {"installations", "account", "purchases", "shares", "note"}
    assert data["account"]["google_sub"] == "sub-export"
    assert data["installations"][0]["device_hash"] == inst.device_hash
    assert data["purchases"][0]["order_id"] == "GPA.1"
    assert data["shares"][0]["scene"]["paysage"] == "cascade-foret"
    text = response.content.decode()
    assert token not in text and inst.token_hash not in text


@pytest.mark.django_db
def test_export_without_account(api):
    data = api.get("/v1/account/export").json()
    assert data["account"] is None
    assert len(data["installations"]) == 1


@pytest.mark.django_db
def test_delete_unlinked_installation(installation):
    inst, token = installation
    client = client_for(token)
    client.post("/v1/shares", {"scene": SCENE}, format="json")
    make_purchase(installation=inst)
    assert client.delete("/v1/account").status_code == 204
    assert not Installation.objects.exists()
    assert not Share.objects.exists() and not Purchase.objects.exists()
    assert client.get("/v1/entitlements").status_code == 401


@pytest.mark.django_db
def test_delete_linked_account_removes_every_linked_installation():
    other, _ = make_installation()  # someone else: untouched
    _inst_a, token_a = make_installation()
    _inst_b, token_b = make_installation()
    link(client_for(token_a), sub="p")
    link(client_for(token_b), sub="p")
    account = Account.objects.get(google_sub="p")
    make_purchase(account=account)
    client_for(token_b).post("/v1/shares", {"scene": SCENE}, format="json")
    assert client_for(token_a).delete("/v1/account").status_code == 204
    assert list(Installation.objects.all()) == [other]
    assert not Account.objects.exists()
    assert not Purchase.objects.exists() and not Share.objects.exists()
