import json
from datetime import timedelta
from io import StringIO

import pytest
from django.core.management import call_command
from django.utils import timezone

from apps.core.models import RateCounter
from apps.voice import quota
from apps.voice.models import VoiceRequest
from conftest import make_installation


@pytest.mark.django_db
def test_purge_expired_releases_stale_reservations_and_old_rows():
    installation, _ = make_installation()
    stale = quota.reserve(installation, mode="trial", source="model")
    VoiceRequest.objects.filter(pk=stale.pk).update(created_at=timezone.now() - timedelta(hours=1))
    old = quota.reserve(installation, mode="trial", source="local")
    VoiceRequest.objects.filter(pk=old.pk).update(created_at=timezone.now() - timedelta(days=200))
    RateCounter.objects.create(scope="t", key="k", window_start=timezone.now() - timedelta(days=5))
    out = StringIO()
    call_command("purge_expired", stdout=out)
    summary = json.loads(out.getvalue())
    assert summary["event"] == "purge_expired_done"
    assert summary["released_reservations"] == 1
    assert summary["rate_counters"] == 1
    assert summary["voice_requests"] >= 1
    installation.refresh_from_db()
    assert installation.trial_used == 1  # the stale model request was given back


@pytest.mark.django_db
def test_deploy_check_warns_when_integrity_is_off(settings):
    from apps.core.checks import eventide_deploy_checks

    settings.PLAY_INTEGRITY_ENFORCED = False
    ids = [w.id for w in eventide_deploy_checks(None)]
    assert "eventide.W001" in ids
    settings.PLAY_INTEGRITY_ENFORCED = True
    settings.GEMINI_MODEL = "unknown-model"
    assert [w.id for w in eventide_deploy_checks(None)] == ["eventide.W002"]
