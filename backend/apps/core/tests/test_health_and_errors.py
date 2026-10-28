import pytest
from django.db import connection
from rest_framework.test import APIClient

from apps.core.clientip import client_ip, ip_key


def test_health_without_database_and_any_host(client):
    response = client.get("/v1/health", HTTP_HOST="10.20.10.37:8000")
    assert response.status_code == 200
    assert response.json() == {"status": "ok"}


@pytest.mark.django_db
def test_ready_checks_the_database(client):
    response = client.get("/v1/health/ready")
    assert response.status_code == 200
    assert response.json() == {"status": "ok"}


@pytest.mark.django_db
def test_ready_answers_503_when_the_database_fails(client, monkeypatch):
    def broken(*args, **kwargs):
        raise RuntimeError("down")

    monkeypatch.setattr(connection, "cursor", broken)
    response = client.get("/v1/health/ready")
    assert response.status_code == 503
    assert response.json() == {"status": "unavailable"}


@pytest.mark.django_db
def test_missing_token_is_401_with_envelope():
    response = APIClient().get("/v1/entitlements")
    assert response.status_code == 401
    assert response.json() == {
        "error": "unauthorized",
        "detail": "Jeton d'installation absent ou invalide.",
    }
    assert response["WWW-Authenticate"].startswith("Bearer")


@pytest.mark.django_db
@pytest.mark.parametrize(
    "header",
    [
        "Bearer",
        "Bearer a b",
        "Basic abcdefghijklmnopqrstuvwxyz",
        "Bearer short",
        "Bearer " + "x" * 43,
    ],
)
def test_bad_tokens_are_401(header):
    response = APIClient().get("/v1/entitlements", HTTP_AUTHORIZATION=header)
    assert response.status_code == 401
    assert response.json()["error"] == "unauthorized"


@pytest.mark.django_db
def test_unknown_route_is_json_404(client):
    response = client.get("/v1/nope")
    assert response.status_code == 404
    assert response.json() == {"error": "not_found", "detail": "Introuvable."}


@pytest.mark.django_db
def test_wrong_method_is_405(api):
    response = api.put("/v1/entitlements", {}, format="json")
    assert response.status_code == 405
    assert response.json()["error"] == "method_not_allowed"


@pytest.mark.django_db
def test_malformed_json_is_400(api):
    response = api.post("/v1/shares", data="{nope", content_type="application/json")
    assert response.status_code == 400
    assert response.json()["error"] == "invalid_request"


@pytest.mark.django_db
def test_non_json_body_is_415(api):
    response = api.post("/v1/shares", data="a=b", content_type="application/x-www-form-urlencoded")
    assert response.status_code == 415
    assert response.json()["error"] == "unsupported_media_type"


@pytest.mark.django_db
def test_too_large_body_is_413(api):
    body = '{"scene": "' + "x" * 70_000 + '"}'
    response = api.post("/v1/shares", data=body, content_type="application/json")
    assert response.status_code == 413
    assert response.json()["error"] == "payload_too_large"


def test_client_ip_takes_the_address_appended_by_the_alb(rf, settings):
    settings.NUM_PROXIES = 1
    request = rf.get("/", HTTP_X_FORWARDED_FOR="6.6.6.6, 203.0.113.9", REMOTE_ADDR="10.0.0.1")
    assert client_ip(request) == "203.0.113.9"
    settings.NUM_PROXIES = 0
    assert client_ip(request) == "10.0.0.1"
    assert len(ip_key(request)) == 32 and "10.0.0.1" not in ip_key(request)


def test_request_id_header(client):
    response = client.get("/v1/health")
    assert response.status_code == 200
    response = client.get("/confidentialite")
    assert response.has_header("X-Request-Id")
