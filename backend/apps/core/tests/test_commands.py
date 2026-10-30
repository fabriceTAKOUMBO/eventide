import json
from datetime import timedelta
from io import StringIO

import pytest
from django.core.management import call_command
from django.utils import timezone

from apps.core.models import RateCounter


@pytest.mark.django_db
def test_purge_expired_removes_old_rate_counters_only():
    RateCounter.objects.create(scope="t", key="k", window_start=timezone.now() - timedelta(days=5))
    RateCounter.objects.create(scope="t", key="k", window_start=timezone.now())
    out = StringIO()
    call_command("purge_expired", stdout=out)
    summary = json.loads(out.getvalue())
    assert summary == {
        "event": "purge_expired_done",
        "rate_counters": 1,
        "admin_log_entries": 0,
        "sessions": 0,
    }
    assert RateCounter.objects.count() == 1


@pytest.mark.django_db
def test_deploy_check_warns_when_integrity_is_off(settings):
    from apps.core.checks import eventide_deploy_checks

    settings.PLAY_INTEGRITY_ENFORCED = False
    assert [w.id for w in eventide_deploy_checks(None)] == ["eventide.W001"]
    settings.PLAY_INTEGRITY_ENFORCED = True
    assert eventide_deploy_checks(None) == []


def test_google_session_placeholder_secret_is_not_configured(settings):
    from apps.core import google

    settings.GOOGLE_PLAY_SERVICE_ACCOUNT_JSON = "A_REMPLACER"
    with pytest.raises(google.GoogleNotConfigured):
        google.authorized_session()


def test_google_session_with_a_service_account(settings):
    from cryptography.hazmat.primitives import serialization
    from cryptography.hazmat.primitives.asymmetric import rsa

    from apps.core import google

    key = rsa.generate_private_key(public_exponent=65537, key_size=2048)
    pem = key.private_bytes(
        serialization.Encoding.PEM, serialization.PrivateFormat.PKCS8, serialization.NoEncryption()
    ).decode()
    settings.GOOGLE_PLAY_SERVICE_ACCOUNT_JSON = json.dumps(
        {
            "type": "service_account",
            "project_id": "eventide-test",
            "private_key_id": "k1",
            "private_key": pem,
            "client_email": "play@eventide-test.iam.gserviceaccount.com",
            "client_id": "1",
            "token_uri": "https://oauth2.googleapis.com/token",
        }
    )
    session = google.authorized_session()
    assert google.authorized_session() is session  # one session per process
    assert set(session.credentials.scopes) == set(google.SCOPES)
