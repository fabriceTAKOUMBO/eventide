import base64
import hashlib
import secrets
import threading
import time

import pytest
from django.db import connection
from rest_framework.test import APIClient

from apps.installations.models import Installation
from apps.installations.tokens import hash_token
from conftest import client_for, make_purchase

PKG = "app.eventide.test"
DECODE_URL = f"https://playintegrity.googleapis.com/v1/{PKG}:decodeIntegrityToken"


def request_hash() -> str:
    digest = hashlib.sha256(secrets.token_bytes(16)).digest()
    return base64.urlsafe_b64encode(digest).decode().rstrip("=")


def body(**overrides):
    data = {
        "integrity_token": "integrity-token-from-play",
        "request_hash": request_hash(),
        "device_hash": secrets.token_hex(32),
        "app_version": "1.0.0",
    }
    data.update(overrides)
    return data


def verdict(rh: str, **overrides) -> dict:
    payload = {
        "requestDetails": {
            "requestPackageName": PKG,
            "requestHash": rh,
            "timestampMillis": str(int(time.time() * 1000)),
        },
        "appIntegrity": {"appRecognitionVerdict": "PLAY_RECOGNIZED", "packageName": PKG},
        "deviceIntegrity": {"deviceRecognitionVerdict": ["MEETS_DEVICE_INTEGRITY"]},
        "accountDetails": {"appLicensingVerdict": "LICENSED"},
    }
    for key, value in overrides.items():
        payload[key] = value
    return {"tokenPayloadExternal": payload}


@pytest.mark.django_db
def test_register_with_a_good_verdict(google_http):
    data = body()
    google_http.post(DECODE_URL, json=verdict(data["request_hash"]))
    response = APIClient().post("/v1/installations", data, format="json")
    assert response.status_code == 201
    payload = response.json()
    assert set(payload) == {"installation_id", "token"}
    assert len(payload["token"]) == 43
    stored = Installation.objects.get(pk=payload["installation_id"])
    assert stored.device_hash == data["device_hash"]
    assert stored.token_hash == hash_token(payload["token"])
    assert payload["token"] not in stored.token_hash  # only the hash is stored
    assert google_http.calls[0].request.body == b'{"integrity_token": "integrity-token-from-play"}'
    # The token authenticates.
    assert client_for(payload["token"]).get("/v1/entitlements").status_code == 200


@pytest.mark.django_db
def test_same_device_gets_a_new_token_and_the_old_one_is_revoked(settings):
    settings.PLAY_INTEGRITY_ENFORCED = False
    data = body()
    first = APIClient().post("/v1/installations", data, format="json").json()
    second = APIClient().post("/v1/installations", data, format="json").json()
    assert first["installation_id"] == second["installation_id"]
    assert first["token"] != second["token"]
    assert client_for(first["token"]).get("/v1/entitlements").status_code == 401
    assert client_for(second["token"]).get("/v1/entitlements").status_code == 200
    assert Installation.objects.count() == 1


@pytest.mark.django_db
def test_reinstall_keeps_the_purchases(settings):
    settings.PLAY_INTEGRITY_ENFORCED = False
    data = body()
    first = APIClient().post("/v1/installations", data, format="json").json()
    make_purchase(installation=Installation.objects.get(pk=first["installation_id"]))
    second = APIClient().post("/v1/installations", data, format="json").json()
    response = client_for(second["token"]).get("/v1/entitlements").json()
    assert response["plan"] == "monthly"


@pytest.mark.django_db
@pytest.mark.parametrize(
    "overrides",
    [
        {"device_hash": "ABC"},
        {"device_hash": "G" * 64},
        {"request_hash": "short"},
        {"app_version": "v1"},
        {"integrity_token": 12},
        {"integrity_token": "x" * 8193},
    ],
)
def test_invalid_bodies_are_400(overrides):
    response = APIClient().post("/v1/installations", body(**overrides), format="json")
    assert response.status_code == 400
    assert response.json()["error"] == "invalid_request"


@pytest.mark.django_db
def test_empty_integrity_token_is_403_when_enforced(google_http):
    response = APIClient().post("/v1/installations", body(integrity_token=""), format="json")
    assert response.status_code == 403
    assert response.json()["error"] == "integrity_failed"
    assert len(google_http.calls) == 0


@pytest.mark.django_db
def test_empty_integrity_token_is_accepted_when_not_enforced(settings):
    settings.PLAY_INTEGRITY_ENFORCED = False
    response = APIClient().post("/v1/installations", body(integrity_token=""), format="json")
    assert response.status_code == 201


@pytest.mark.django_db
def test_non_object_body_is_400():
    response = APIClient().post("/v1/installations", [1, 2], format="json")
    assert response.status_code == 400


@pytest.mark.django_db
@pytest.mark.parametrize(
    "change",
    [
        {"appIntegrity": {"appRecognitionVerdict": "UNRECOGNIZED_VERSION"}},
        {"deviceIntegrity": {"deviceRecognitionVerdict": ["MEETS_BASIC_INTEGRITY"]}},
        {"deviceIntegrity": {}},
        {
            "requestDetails": {
                "requestPackageName": "com.other.app",
                "requestHash": "x",
                "timestampMillis": "0",
            }
        },
    ],
)
def test_bad_verdicts_are_403(google_http, change):
    data = body()
    google_http.post(DECODE_URL, json=verdict(data["request_hash"], **change))
    response = APIClient().post("/v1/installations", data, format="json")
    assert response.status_code == 403
    assert response.json()["error"] == "integrity_failed"
    assert Installation.objects.count() == 0


@pytest.mark.django_db
def test_verdict_bound_to_another_request_is_403(google_http):
    data = body()
    google_http.post(DECODE_URL, json=verdict(request_hash()))
    assert APIClient().post("/v1/installations", data, format="json").status_code == 403


@pytest.mark.django_db
def test_old_verdict_is_403(google_http):
    data = body()
    old = verdict(data["request_hash"])
    old["tokenPayloadExternal"]["requestDetails"]["timestampMillis"] = str(
        int((time.time() - 3600) * 1000)
    )
    google_http.post(DECODE_URL, json=old)
    assert APIClient().post("/v1/installations", data, format="json").status_code == 403


@pytest.mark.django_db
def test_token_rejected_by_google_is_403(google_http):
    google_http.post(DECODE_URL, status=400, json={"error": {"code": 400}})
    assert APIClient().post("/v1/installations", body(), format="json").status_code == 403


@pytest.mark.django_db
@pytest.mark.parametrize("status", [500, 503, 401])
def test_google_errors_are_503(google_http, status):
    google_http.post(DECODE_URL, status=status, json={})
    response = APIClient().post("/v1/installations", body(), format="json")
    assert response.status_code == 503
    assert response.json()["error"] == "integrity_unavailable"


@pytest.mark.django_db
def test_google_not_configured_is_503():
    # No service account in the test settings: the real session factory refuses.
    response = APIClient().post("/v1/installations", body(), format="json")
    assert response.status_code == 503
    assert response.json()["error"] == "integrity_unavailable"


@pytest.mark.django_db
def test_rate_limit_per_device(settings):
    settings.PLAY_INTEGRITY_ENFORCED = False
    settings.RATE_INSTALLATIONS_PER_DEVICE_DAY = 2
    data = body()
    for _ in range(2):
        assert APIClient().post("/v1/installations", data, format="json").status_code == 201
    response = APIClient().post("/v1/installations", data, format="json")
    assert response.status_code == 429
    assert response.json()["error"] == "rate_limited"
    assert int(response["Retry-After"]) > 0


@pytest.mark.django_db
def test_rate_limit_per_ip(settings):
    settings.PLAY_INTEGRITY_ENFORCED = False
    settings.RATE_INSTALLATIONS_PER_IP_HOUR = 1
    headers = {"HTTP_X_FORWARDED_FOR": "198.51.100.7"}
    assert (
        APIClient().post("/v1/installations", body(), format="json", **headers).status_code == 201
    )
    second = APIClient().post("/v1/installations", body(), format="json", **headers)
    assert second.status_code == 429
    other = {"HTTP_X_FORWARDED_FOR": "198.51.100.8"}
    assert APIClient().post("/v1/installations", body(), format="json", **other).status_code == 201


@pytest.mark.django_db(transaction=True)
def test_concurrent_first_registration_of_one_device(settings):
    settings.PLAY_INTEGRITY_ENFORCED = False
    data = body()
    barrier = threading.Barrier(4)
    codes = []

    def worker():
        barrier.wait()
        try:
            codes.append(APIClient().post("/v1/installations", data, format="json").status_code)
        finally:
            connection.close()

    threads = [threading.Thread(target=worker) for _ in range(4)]
    for t in threads:
        t.start()
    for t in threads:
        t.join()
    assert codes == [201] * 4
    assert Installation.objects.filter(device_hash=data["device_hash"]).count() == 1


@pytest.mark.django_db
def test_last_seen_is_refreshed_at_most_hourly(installation):
    from datetime import timedelta

    from django.utils import timezone

    inst, token = installation
    old = timezone.now() - timedelta(hours=2)
    Installation.objects.filter(pk=inst.pk).update(last_seen_at=old)
    client_for(token).get("/v1/entitlements")
    inst.refresh_from_db()
    assert inst.last_seen_at > old
