import base64
import json
from datetime import timedelta
from unittest import mock

import pytest
from django.core.management import call_command
from django.utils import timezone

from apps.accounts.models import Account
from apps.entitlements import purchases
from apps.entitlements.models import Purchase
from apps.installations.models import Installation
from conftest import client_for, make_installation, make_purchase

PKG = "app.eventide.test"
API = f"https://androidpublisher.googleapis.com/androidpublisher/v3/applications/{PKG}"


def sub_url(token):
    return f"{API}/purchases/subscriptionsv2/tokens/{token}"


def product_url(product, token, action=""):
    return f"{API}/purchases/products/{product}/tokens/{token}{action}"


def sub_ack_url(token):
    return f"{API}/purchases/subscriptions/eventide_premium/tokens/{token}:acknowledge"


def subscription(
    state="SUBSCRIPTION_STATE_ACTIVE", plan="annual", days=365, ack=False, linked=None
):
    data = {
        "subscriptionState": state,
        "acknowledgementState": "ACKNOWLEDGEMENT_STATE_ACKNOWLEDGED"
        if ack
        else "ACKNOWLEDGEMENT_STATE_PENDING",
        "latestOrderId": "GPA.1234-5678-9012-34567",
        "lineItems": [
            {
                "productId": "eventide_premium",
                "expiryTime": (timezone.now() + timedelta(days=days))
                .isoformat()
                .replace("+00:00", "Z"),
                "autoRenewingPlan": {"autoRenewEnabled": True},
                "offerDetails": {"basePlanId": plan},
            }
        ],
    }
    if linked:
        data["linkedPurchaseToken"] = linked
    return data


def product(state=0, consumed=0, ack=0, quantity=1):
    return {
        "purchaseState": state,
        "consumptionState": consumed,
        "acknowledgementState": ack,
        "orderId": "GPA.9999-0000",
        "quantity": quantity,
    }


@pytest.mark.django_db
def test_free_entitlements_by_default(api):
    assert api.get("/v1/entitlements").json() == {
        "plan": "free",
        "premium": False,
        "expires_at": None,
        "auto_renewing": False,
        "voice": {
            "mode": "trial",
            "trial_remaining": 3,
            "credits_remaining": 0,
            "monthly_cap_reached": False,
        },
    }


@pytest.mark.django_db
def test_subscription_is_verified_acknowledged_and_entitles(api, google_http):
    google_http.get(sub_url("tok-sub"), json=subscription())
    google_http.post(sub_ack_url("tok-sub"), json={})
    response = api.post(
        "/v1/purchases",
        {"product_id": "eventide_premium", "purchase_token": "tok-sub", "base_plan_id": "annual"},
        format="json",
    )
    assert response.status_code == 200
    body = response.json()
    assert body["plan"] == "annual" and body["premium"] is True
    assert body["auto_renewing"] is True and body["expires_at"].endswith("Z")
    assert body["voice"]["mode"] == "included"
    purchase = Purchase.objects.get(purchase_token="tok-sub")
    assert purchase.acknowledged is True
    assert [c.request.method for c in google_http.calls] == ["GET", "POST"]


@pytest.mark.django_db
def test_google_base_plan_wins_over_the_client(api, google_http):
    google_http.get(sub_url("tok-m"), json=subscription(plan="monthly", ack=True))
    response = api.post(
        "/v1/purchases",
        {"product_id": "eventide_premium", "purchase_token": "tok-m", "base_plan_id": "annual"},
        format="json",
    )
    assert response.json()["plan"] == "monthly"


@pytest.mark.django_db
def test_same_token_twice_is_idempotent(api, google_http):
    google_http.get(sub_url("tok-1"), json=subscription(ack=True))
    for _ in range(2):
        response = api.post(
            "/v1/purchases",
            {"product_id": "eventide_premium", "purchase_token": "tok-1", "base_plan_id": None},
            format="json",
        )
        assert response.status_code == 200
    assert Purchase.objects.filter(purchase_token="tok-1").count() == 1


@pytest.mark.django_db
def test_token_of_another_installation_is_409(api, google_http):
    other, _ = make_installation()
    make_purchase(installation=other, purchase_token="tok-taken")
    response = api.post(
        "/v1/purchases",
        {
            "product_id": "eventide_premium",
            "purchase_token": "tok-taken",
            "base_plan_id": "monthly",
        },
        format="json",
    )
    assert response.status_code == 409
    assert response.json()["error"] == "purchase_owned_by_other_account"
    assert not google_http.calls  # refused before calling Google


@pytest.mark.django_db
def test_token_owned_by_the_linked_account_is_accepted_from_another_device(google_http):
    account = Account.objects.create(google_sub="sub-1")
    make_purchase(account=account, purchase_token="tok-acc")
    _, token = make_installation(account=account)
    google_http.get(sub_url("tok-acc"), json=subscription(ack=True))
    response = client_for(token).post(
        "/v1/purchases",
        {"product_id": "eventide_premium", "purchase_token": "tok-acc", "base_plan_id": "annual"},
        format="json",
    )
    assert response.status_code == 200
    assert response.json()["premium"] is True


@pytest.mark.django_db
@pytest.mark.parametrize("status", [400, 404, 410])
def test_unknown_token_is_402(api, google_http, status):
    google_http.get(sub_url("bad"), status=status, json={})
    response = api.post(
        "/v1/purchases",
        {"product_id": "eventide_premium", "purchase_token": "bad", "base_plan_id": "monthly"},
        format="json",
    )
    assert response.status_code == 402
    assert response.json()["error"] == "purchase_invalid"
    assert not Purchase.objects.exists()


@pytest.mark.django_db
def test_expired_subscription_is_402(api, google_http):
    google_http.get(sub_url("old"), json=subscription(state="SUBSCRIPTION_STATE_EXPIRED", days=-3))
    response = api.post(
        "/v1/purchases",
        {"product_id": "eventide_premium", "purchase_token": "old", "base_plan_id": "monthly"},
        format="json",
    )
    assert response.status_code == 402


@pytest.mark.django_db
def test_subscription_for_another_product_is_402(api, google_http):
    data = subscription()
    data["lineItems"][0]["productId"] = "other_product"
    google_http.get(sub_url("x"), json=data)
    response = api.post(
        "/v1/purchases",
        {"product_id": "eventide_premium", "purchase_token": "x", "base_plan_id": "monthly"},
        format="json",
    )
    assert response.status_code == 402


@pytest.mark.django_db
@pytest.mark.parametrize("status", [500, 503, 401, 403])
def test_google_unavailable_is_503(api, google_http, status):
    google_http.get(sub_url("t"), status=status, json={})
    response = api.post(
        "/v1/purchases",
        {"product_id": "eventide_premium", "purchase_token": "t", "base_plan_id": "monthly"},
        format="json",
    )
    assert response.status_code == 503
    assert response.json()["error"] == "play_unavailable"


@pytest.mark.django_db
def test_play_not_configured_is_503(api):
    response = api.post(
        "/v1/purchases",
        {"product_id": "eventide_lifetime", "purchase_token": "t", "base_plan_id": None},
        format="json",
    )
    assert response.status_code == 503


@pytest.mark.django_db
@pytest.mark.parametrize(
    "data",
    [
        {"product_id": "other", "purchase_token": "t", "base_plan_id": None},
        {"product_id": "eventide_premium", "purchase_token": "", "base_plan_id": "monthly"},
        {"product_id": "eventide_premium", "purchase_token": "t", "base_plan_id": "weekly"},
        {"product_id": "eventide_lifetime", "purchase_token": "t", "base_plan_id": "monthly"},
        {"product_id": "eventide_credits_50", "purchase_token": 3, "base_plan_id": None},
    ],
)
def test_invalid_purchase_bodies_are_400(api, data):
    assert api.post("/v1/purchases", data, format="json").status_code == 400


@pytest.mark.django_db
def test_lifetime_purchase_is_acknowledged(api, google_http):
    google_http.get(product_url("eventide_lifetime", "life"), json=product())
    google_http.post(product_url("eventide_lifetime", "life", ":acknowledge"), json={})
    response = api.post(
        "/v1/purchases",
        {"product_id": "eventide_lifetime", "purchase_token": "life", "base_plan_id": None},
        format="json",
    )
    body = response.json()
    assert body["plan"] == "lifetime" and body["premium"] is True
    assert body["voice"]["mode"] == "credits"
    assert Purchase.objects.get(purchase_token="life").acknowledged is True


@pytest.mark.django_db
def test_pending_lifetime_is_recorded_without_entitlement(api, google_http):
    google_http.get(product_url("eventide_lifetime", "pend"), json=product(state=2))
    response = api.post(
        "/v1/purchases",
        {"product_id": "eventide_lifetime", "purchase_token": "pend", "base_plan_id": None},
        format="json",
    )
    assert response.status_code == 200
    assert response.json()["plan"] == "free"
    assert Purchase.objects.get(purchase_token="pend").state == "pending"


@pytest.mark.django_db
def test_credits_are_granted_once_and_consumed(api, installation, google_http):
    inst, _ = installation
    google_http.get(product_url("eventide_credits_50", "cr"), json=product())
    consume = google_http.post(product_url("eventide_credits_50", "cr", ":consume"), json={})
    body = {"product_id": "eventide_credits_50", "purchase_token": "cr", "base_plan_id": None}
    first = api.post("/v1/purchases", body, format="json").json()
    assert first["voice"]["credits_remaining"] == 50
    # Same token again (app retry): no second grant, no second consume.
    google_http.get(product_url("eventide_credits_50", "cr"), json=product(consumed=1))
    second = api.post("/v1/purchases", body, format="json").json()
    assert second["voice"]["credits_remaining"] == 50
    inst.refresh_from_db()
    assert inst.credits == 50
    assert consume.call_count == 1
    assert Purchase.objects.get(purchase_token="cr").consumed is True


@pytest.mark.django_db
def test_failed_consume_is_retried_by_the_command(api, installation, google_http):
    inst, _ = installation
    google_http.get(product_url("eventide_credits_50", "cr2"), json=product(quantity=2))
    google_http.post(product_url("eventide_credits_50", "cr2", ":consume"), status=503, json={})
    body = {"product_id": "eventide_credits_50", "purchase_token": "cr2", "base_plan_id": None}
    assert (
        api.post("/v1/purchases", body, format="json").json()["voice"]["credits_remaining"] == 100
    )
    purchase = Purchase.objects.get(purchase_token="cr2")
    assert purchase.consumed is False
    google_http.replace("POST", product_url("eventide_credits_50", "cr2", ":consume"), json={})
    call_command("finalize_purchases")
    purchase.refresh_from_db()
    assert purchase.consumed is True
    inst.refresh_from_db()
    assert inst.credits == 100


@pytest.mark.django_db
def test_upgrade_replaces_the_linked_purchase(api, installation, google_http):
    inst, _ = installation
    make_purchase(installation=inst, purchase_token="tok-old", base_plan_id="monthly")
    google_http.get(sub_url("tok-new"), json=subscription(ack=True, linked="tok-old"))
    api.post(
        "/v1/purchases",
        {"product_id": "eventide_premium", "purchase_token": "tok-new", "base_plan_id": "annual"},
        format="json",
    )
    assert Purchase.objects.get(purchase_token="tok-old").state == "replaced"
    assert api.get("/v1/entitlements").json()["plan"] == "annual"


@pytest.mark.django_db
def test_rate_limit_on_purchases(api, settings):
    settings.RATE_PURCHASES_PER_HOUR = 1
    body = {"product_id": "x", "purchase_token": "t", "base_plan_id": None}
    good = {"product_id": "eventide_lifetime", "purchase_token": "t", "base_plan_id": None}
    assert api.post("/v1/purchases", body, format="json").status_code == 400
    assert api.post("/v1/purchases", good, format="json").status_code == 503
    assert api.post("/v1/purchases", good, format="json").status_code == 429


@pytest.mark.django_db(transaction=True)
def test_concurrent_posts_of_the_same_token_record_one_purchase():
    import threading

    from django.db import connection

    inst, _ = make_installation()
    owner = purchases.Owner(installation=inst, account=None)
    barrier = threading.Barrier(2)
    results = []

    def fetch(kind, product_id, token):
        barrier.wait()  # both requests looked the token up before either records it
        return {
            "state": "active",
            "base_plan_id": "",
            "expires_at": None,
            "auto_renewing": False,
            "order_id": "GPA.1",
            "google_acknowledged": True,
            "google_consumed": True,
            "quantity": 1,
        }

    def worker():
        try:
            results.append(purchases.submit(owner, product_id="eventide_credits_50", token="race"))
        finally:
            connection.close()

    with mock.patch.object(purchases, "_fetch", side_effect=fetch):
        threads = [threading.Thread(target=worker) for _ in range(2)]
        for t in threads:
            t.start()
        for t in threads:
            t.join()
    assert len(results) == 2
    assert Purchase.objects.filter(purchase_token="race").count() == 1
    inst.refresh_from_db()
    assert inst.credits == 50  # granted once despite the race


# --- Real-time developer notifications -------------------------------------------------------


def push(notification: dict) -> dict:
    data = base64.b64encode(json.dumps(notification).encode()).decode()
    return {
        "message": {"data": data, "messageId": "1"},
        "subscription": "projects/p/subscriptions/s",
    }


GOOD_CLAIMS = {
    "email": "rtdn-push@eventide-test.iam.gserviceaccount.com",
    "email_verified": True,
    "aud": "https://api.eventide.test/v1/play/rtdn",
}


@pytest.fixture
def pubsub_token():
    with mock.patch(
        "google.oauth2.id_token.verify_oauth2_token", return_value=dict(GOOD_CLAIMS)
    ) as verify:
        yield verify


def rtdn(client, payload, token="signed.jwt.token"):
    return client.post(
        "/v1/play/rtdn",
        json.dumps(payload),
        content_type="application/json",
        HTTP_AUTHORIZATION=f"Bearer {token}",
    )


@pytest.mark.django_db
def test_rtdn_without_token_is_401(client):
    response = client.post("/v1/play/rtdn", push({}), content_type="application/json")
    assert response.status_code == 401


@pytest.mark.django_db
def test_rtdn_with_invalid_token_is_401(client):
    with mock.patch("google.oauth2.id_token.verify_oauth2_token", side_effect=ValueError("bad")):
        assert rtdn(client, push({"packageName": PKG})).status_code == 401


@pytest.mark.django_db
def test_rtdn_from_another_service_account_is_401(client):
    claims = dict(GOOD_CLAIMS, email="someone@else.iam.gserviceaccount.com")
    with mock.patch("google.oauth2.id_token.verify_oauth2_token", return_value=claims):
        assert rtdn(client, push({"packageName": PKG})).status_code == 401


@pytest.mark.django_db
def test_rtdn_checks_the_audience(client, pubsub_token):
    rtdn(client, push({"packageName": PKG, "testNotification": {"version": "1.0"}}))
    assert pubsub_token.call_args.kwargs["audience"] == "https://api.eventide.test/v1/play/rtdn"


@pytest.mark.django_db
def test_rtdn_test_and_unknown_notifications_are_204(client, pubsub_token):
    assert rtdn(client, push({"packageName": PKG, "testNotification": {}})).status_code == 204
    assert rtdn(client, push({"packageName": "other.app"})).status_code == 204
    unknown = {"packageName": PKG, "subscriptionNotification": {"purchaseToken": "nobody"}}
    assert rtdn(client, push(unknown)).status_code == 204
    assert rtdn(client, push({"packageName": PKG})).status_code == 204


@pytest.mark.django_db
def test_rtdn_malformed_is_400(client, pubsub_token):
    assert rtdn(client, {"message": {"data": "%%%"}}).status_code == 400
    assert rtdn(client, {"nope": 1}).status_code == 400


@pytest.mark.django_db
def test_rtdn_renewal_and_expiry_refresh_the_state(client, pubsub_token, google_http):
    inst, token = make_installation()
    make_purchase(installation=inst, purchase_token="tok-r", expires_at=timezone.now())
    assert client_for(token).get("/v1/entitlements").json()["plan"] == "free"
    google_http.get(sub_url("tok-r"), json=subscription(plan="monthly", days=30, ack=True))
    note = {
        "packageName": PKG,
        "subscriptionNotification": {"notificationType": 2, "purchaseToken": "tok-r"},
    }
    assert rtdn(client, push(note)).status_code == 204
    assert client_for(token).get("/v1/entitlements").json()["plan"] == "monthly"
    google_http.replace(
        "GET", sub_url("tok-r"), json=subscription(state="SUBSCRIPTION_STATE_EXPIRED", days=-1)
    )
    assert rtdn(client, push(note)).status_code == 204
    assert client_for(token).get("/v1/entitlements").json()["plan"] == "free"


@pytest.mark.django_db
def test_rtdn_google_down_is_503_so_pubsub_retries(client, pubsub_token, google_http):
    inst, _ = make_installation()
    make_purchase(installation=inst, purchase_token="tok-d")
    google_http.get(sub_url("tok-d"), status=500, json={})
    note = {"packageName": PKG, "subscriptionNotification": {"purchaseToken": "tok-d"}}
    assert rtdn(client, push(note)).status_code == 503


@pytest.mark.django_db
def test_rtdn_unknown_token_at_google_revokes(client, pubsub_token, google_http):
    inst, _ = make_installation()
    make_purchase(installation=inst, purchase_token="tok-g")
    google_http.get(sub_url("tok-g"), status=410, json={})
    note = {"packageName": PKG, "subscriptionNotification": {"purchaseToken": "tok-g"}}
    assert rtdn(client, push(note)).status_code == 204
    assert Purchase.objects.get(purchase_token="tok-g").state == "revoked"


@pytest.mark.django_db
def test_rtdn_voided_credits_takes_back_what_is_left(client, pubsub_token):
    inst, _ = make_installation(credits=30)
    make_purchase(
        installation=inst,
        purchase_token="tok-v",
        product_id="eventide_credits_50",
        kind="credits",
        base_plan_id="",
        expires_at=None,
        credits_granted=50,
        consumed=True,
    )
    note = {"packageName": PKG, "voidedPurchaseNotification": {"purchaseToken": "tok-v"}}
    assert rtdn(client, push(note)).status_code == 204
    assert rtdn(client, push(note)).status_code == 204  # idempotent
    inst.refresh_from_db()
    assert inst.credits == 0
    assert Purchase.objects.get(purchase_token="tok-v").state == "revoked"


@pytest.mark.django_db
def test_rtdn_completed_pending_credits_are_granted(client, pubsub_token, google_http):
    inst, _ = make_installation()
    make_purchase(
        installation=inst,
        purchase_token="tok-p",
        product_id="eventide_credits_50",
        kind="credits",
        state="pending",
        base_plan_id="",
        expires_at=None,
    )
    google_http.get(product_url("eventide_credits_50", "tok-p"), json=product())
    google_http.post(product_url("eventide_credits_50", "tok-p", ":consume"), json={})
    note = {"packageName": PKG, "oneTimeProductNotification": {"purchaseToken": "tok-p"}}
    assert rtdn(client, push(note)).status_code == 204
    inst.refresh_from_db()
    assert inst.credits == 50


@pytest.mark.django_db
def test_entitled_states_and_priority(installation):
    inst, token = installation
    api = client_for(token)
    make_purchase(
        installation=inst, kind="lifetime", product_id="eventide_lifetime", expires_at=None
    )
    assert api.get("/v1/entitlements").json()["plan"] == "lifetime"
    make_purchase(installation=inst, state="canceled", base_plan_id="monthly")
    body = api.get("/v1/entitlements").json()
    assert body["plan"] == "monthly" and body["voice"]["mode"] == "included"
    Installation.objects.filter(pk=inst.pk).update(credits=4)
    assert api.get("/v1/entitlements").json()["voice"]["credits_remaining"] == 4


@pytest.mark.django_db
def test_voice_disabled_mode_none(api, settings):
    settings.VOICE_ENABLED = False
    assert api.get("/v1/entitlements").json()["voice"]["mode"] == "none"
