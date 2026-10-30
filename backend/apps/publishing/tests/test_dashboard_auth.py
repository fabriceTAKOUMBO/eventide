"""Dashboard sign-in and protection (contract § 14)."""

import logging
import uuid
from unittest import mock

import pytest
from django.conf import settings
from django.contrib.sessions.models import Session
from django.test import Client
from google.auth import exceptions as google_exceptions

from apps.accounts.models import Account
from apps.publishing import admin_auth
from apps.publishing.models import AdminLogEntry, PublishedItem

from .conftest import ADMIN_EMAIL, VERIFY, claims, sign_in

LOGIN = "/tableau/connexion"


def post_login(client, token_claims=None, *, side_effect=None, credential="header.payload.sig"):
    with mock.patch(VERIFY, return_value=token_claims, side_effect=side_effect) as verify:
        response = client.post(LOGIN, {"credential": credential})
    return response, verify


def assert_dashboard_headers(response, *, login=False):
    assert response["Cache-Control"] == "no-store"
    assert response["X-Frame-Options"] == "DENY"
    policy = response["Content-Security-Policy"]
    assert "default-src 'none'" in policy and "frame-ancestors 'none'" in policy
    assert "'unsafe-inline'" not in policy
    if login:
        assert "script-src 'self' https://accounts.google.com/gsi/client" in policy
        assert "frame-src https://accounts.google.com/gsi/" in policy
    else:
        assert "accounts.google.com" not in policy


@pytest.mark.django_db
def test_sign_in_page(client):
    response = client.get(LOGIN)
    assert response.status_code == 200
    assert_dashboard_headers(response, login=True)
    html = response.content.decode()
    assert 'data-client-id="client-1.apps.googleusercontent.com"' in html
    assert "tableau/connexion.js" in html and "<script>" not in html
    assert 'name="csrfmiddlewaretoken"' in html
    assert response["Referrer-Policy"] == "strict-origin-when-cross-origin"
    assert response["Cross-Origin-Opener-Policy"] == "same-origin-allow-popups"
    csrf = response.cookies[settings.CSRF_COOKIE_NAME]
    assert csrf["path"] == "/tableau/" and csrf["samesite"] == "Strict" and csrf["secure"]


@pytest.mark.django_db
def test_admin_signs_in_and_only_the_address_hash_is_kept(client, caplog):
    caplog.set_level(logging.DEBUG)
    response, verify = post_login(client, claims())
    assert response.status_code == 302 and response["Location"] == "/tableau/"
    assert verify.call_args.kwargs["audience"] == ["client-1.apps.googleusercontent.com"]
    cookie = response.cookies[settings.SESSION_COOKIE_NAME]
    assert cookie["path"] == "/tableau/"
    assert cookie["httponly"] and cookie["secure"] and cookie["samesite"] == "Strict"
    assert int(cookie["max-age"]) == 8 * 3600
    account = Account.objects.get(google_sub="google-admin-1")
    data = Session.objects.get().get_decoded()
    assert data == {
        admin_auth.SESSION_ACCOUNT: str(account.pk),
        admin_auth.SESSION_EMAIL_HASH: admin_auth.email_hash(ADMIN_EMAIL),
    }
    entry = AdminLogEntry.objects.get()
    assert entry.action == "connexion" and entry.account_id == account.pk
    # The address is never stored nor logged.
    assert "eventide.test" not in str(data).lower()
    assert "eventide.test" not in caplog.text.lower()
    assert client.get("/tableau/").status_code == 200


@pytest.mark.django_db
def test_the_same_account_as_in_the_app_is_used(client):
    existing = Account.objects.create(google_sub="google-admin-1")
    post_login(client, claims())
    assert Account.objects.count() == 1
    assert Session.objects.get().get_decoded()[admin_auth.SESSION_ACCOUNT] == str(existing.pk)


@pytest.mark.django_db
@pytest.mark.parametrize(
    "token_claims",
    [
        claims(email="intrus@example.com"),
        claims(email_verified=False),
        claims(email_verified="false"),
        {k: v for k, v in claims().items() if k != "email_verified"},
        {k: v for k, v in claims().items() if k != "email"},
        {k: v for k, v in claims().items() if k != "sub"},
        claims(aud="other-client.apps.googleusercontent.com"),
    ],
)
def test_refused_sign_ins_show_access_denied_without_detail(client, token_claims):
    response, _ = post_login(client, token_claims)
    assert response.status_code == 403
    assert_dashboard_headers(response, login=True)
    html = response.content.decode()
    assert "Accès refusé" in html and "intrus" not in html
    assert not Session.objects.exists() or not any(
        admin_auth.SESSION_ACCOUNT in s.get_decoded() for s in Session.objects.all()
    )
    assert not Account.objects.exists()
    assert client.get("/tableau/").status_code == 302


@pytest.mark.django_db
def test_invalid_or_wrong_audience_token_is_refused(client):
    response, _ = post_login(client, side_effect=ValueError("Token has wrong audience"))
    assert response.status_code == 403
    response, _ = post_login(client, credential="")
    assert response.status_code == 403
    response, _ = post_login(client, credential="x" * 9000)
    assert response.status_code == 403


@pytest.mark.django_db
def test_no_admin_configured_refuses_everyone(client, settings):
    settings.ADMIN_EMAILS = []
    response, verify = post_login(client, claims())
    assert response.status_code == 403
    assert not verify.called
    assert "pas configurée" in client.get(LOGIN).content.decode()


@pytest.mark.django_db
@pytest.mark.parametrize("value", [["a_remplacer"], ["A_REMPLACER"], ["", "pas-une-adresse"]])
def test_placeholder_admin_emails_mean_no_admin(client, settings, value):
    settings.ADMIN_EMAILS = value
    response, verify = post_login(client, claims())
    assert response.status_code == 403
    assert not verify.called
    assert "pas configurée" in client.get(LOGIN).content.decode()


@pytest.mark.django_db
def test_google_unreachable_is_503(client):
    response, _ = post_login(client, side_effect=google_exceptions.TransportError("down"))
    assert response.status_code == 503
    assert "injoignable" in response.content.decode()


@pytest.mark.django_db
def test_sign_in_attempts_are_limited_per_ip(client):
    for _ in range(10):
        response, _ = post_login(client, claims(email="intrus@example.com"))
        assert response.status_code == 403
    response, _ = post_login(client, claims())
    assert response.status_code == 429
    assert int(response["Retry-After"]) >= 1
    # Another address is not affected (keyed hash of the client IP behind the ALB).
    other = Client(HTTP_X_FORWARDED_FOR="198.51.100.7")
    response, _ = post_login(other, claims())
    assert response.status_code == 302


@pytest.mark.django_db
def test_removing_the_address_cuts_access_at_once(admin_client, settings):
    assert admin_client.get("/tableau/").status_code == 200
    settings.ADMIN_EMAILS = ["second@eventide.test"]
    response = admin_client.get("/tableau/")
    assert response.status_code == 302 and response["Location"] == LOGIN
    assert not Session.objects.filter(
        session_key=admin_client.cookies[settings.SESSION_COOKIE_NAME].value
    ).exists()
    settings.ADMIN_EMAILS = [ADMIN_EMAIL]
    assert admin_client.get("/tableau/").status_code == 302  # the session is gone


@pytest.mark.django_db
def test_a_deleted_account_ends_the_session(admin_client, admin_account):
    admin_account.delete()
    assert admin_client.get("/tableau/").status_code == 302


@pytest.mark.django_db
def test_sign_out_clears_the_session(admin_client):
    response = admin_client.post("/tableau/deconnexion")
    assert response.status_code == 302 and response["Location"] == LOGIN
    cookie = response.cookies[settings.SESSION_COOKIE_NAME]
    assert cookie.value == "" and cookie["path"] == "/tableau/"
    assert not Session.objects.exists()
    assert AdminLogEntry.objects.filter(action="deconnexion").count() == 1
    assert admin_client.get("/tableau/").status_code == 302


@pytest.mark.django_db
def test_signed_in_admin_skips_the_sign_in_page(admin_client):
    response = admin_client.get(LOGIN)
    assert response.status_code == 302 and response["Location"] == "/tableau/"


ELEMENT = "00000000-0000-4000-8000-000000000001"
PAGES = [
    "/tableau/",
    "/tableau/elements/nouveau",
    f"/tableau/elements/{ELEMENT}",
    f"/tableau/elements/{ELEMENT}/modifier",
    "/tableau/utilisateurs",
    "/tableau/journal",
]
FORMS = [
    "/tableau/elements/nouveau",
    f"/tableau/elements/{ELEMENT}/publier",
    f"/tableau/elements/{ELEMENT}/retirer",
    f"/tableau/elements/{ELEMENT}/modifier",
]
JSON = [
    ("get", f"/tableau/elements/{ELEMENT}/etat"),
    ("post", f"/tableau/elements/{ELEMENT}/envoi"),
    ("post", f"/tableau/elements/{ELEMENT}/envoi-termine"),
]


@pytest.fixture
def element(db):
    return PublishedItem.objects.create(
        id=uuid.UUID(ELEMENT), kind="son", item_id="vent-doux", nom="Vent doux"
    )


@pytest.mark.django_db
@pytest.mark.parametrize("url", PAGES)
def test_every_page_requires_the_session(client, element, url):
    response = client.get(url)
    assert response.status_code == 302 and response["Location"] == LOGIN
    assert_dashboard_headers(response)


@pytest.mark.django_db
@pytest.mark.parametrize("url", FORMS)
def test_every_form_requires_the_session(client, element, url):
    response = client.post(url, {"nom": "Pirate"})
    assert response.status_code == 302 and response["Location"] == LOGIN
    element.refresh_from_db()
    assert element.nom == "Vent doux" and element.state == "brouillon"


@pytest.mark.django_db
@pytest.mark.parametrize(("method", "url"), JSON)
def test_every_json_endpoint_requires_the_session(client, element, method, url):
    response = getattr(client, method)(url)
    assert response.status_code == 403
    assert response.json()["error"] == "forbidden"


@pytest.mark.django_db
def test_an_installation_token_gives_no_dashboard_access(api, element):
    """No administration through the v1 API or with an installation token (contract § 14)."""
    response = api.get("/tableau/")
    assert response.status_code == 302


@pytest.mark.django_db
@pytest.mark.parametrize("url", ["/tableau/deconnexion", f"/tableau/elements/{ELEMENT}/publier"])
def test_csrf_is_enforced_on_changes(admin_account, element, url):
    client = sign_in(Client(enforce_csrf_checks=True), admin_account)
    response = client.post(url)
    assert response.status_code == 403
    assert "Formulaire expiré" in response.content.decode()
    assert_dashboard_headers(response)
    assert AdminLogEntry.objects.count() == 0


@pytest.mark.django_db
def test_csrf_is_enforced_on_sign_in():
    client = Client(enforce_csrf_checks=True)
    response, verify = post_login(client, claims())
    assert response.status_code == 403
    assert not verify.called


@pytest.mark.django_db
def test_csrf_token_from_the_page_is_accepted(admin_account, element):
    client = sign_in(Client(enforce_csrf_checks=True), admin_account)
    page = client.get(f"/tableau/elements/{ELEMENT}")
    token = page.content.decode().split('name="csrfmiddlewaretoken" value="')[1].split('"')[0]
    response = client.post(f"/tableau/elements/{ELEMENT}/retirer", {"csrfmiddlewaretoken": token})
    assert response.status_code == 302  # refused action (not online), but CSRF passed
    assert response["Location"].endswith("?message=refus")
    # The JSON endpoints take the token from the page in the X-CSRFToken header.
    response = client.post(f"/tableau/elements/{ELEMENT}/envoi", HTTP_X_CSRFTOKEN=token)
    assert response.status_code == 400  # no extension given: CSRF passed


@pytest.mark.django_db
def test_dashboard_pages_carry_the_security_headers(admin_client, element):
    for url in PAGES:
        response = admin_client.get(url)
        assert response.status_code == 200, url
        assert_dashboard_headers(response)
        policy = response["Content-Security-Policy"]
        assert "connect-src 'self' https://ev-test-content.s3.us-east-1.amazonaws.com" in policy
        assert "form-action 'self' https://ev-test-content.s3.us-east-1.amazonaws.com" in policy
        assert "img-src 'self' https://cdn.eventide.test" in policy
        assert "media-src https://cdn.eventide.test" in policy
        assert response["Referrer-Policy"] == "same-origin"
        assert "<script>" not in response.content.decode()


@pytest.mark.django_db
def test_public_pages_keep_their_strict_policy(client):
    for url in ("/confidentialite", "/s"):
        policy = client.get(url)["Content-Security-Policy"]
        assert "form-action 'none'" in policy and "amazonaws" not in policy
        assert "accounts.google.com" not in policy
