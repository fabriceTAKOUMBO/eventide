"""Quota race safety: concurrent reservations can never exceed a limit."""

import threading
from decimal import Decimal
import pytest
from django.db import connection

from apps.accounts.models import Account
from apps.installations.models import Installation
from apps.voice import quota
from apps.voice.models import VoiceGlobalDay, VoiceMonthlyUsage, VoiceRequest
from conftest import make_installation


def run_concurrently(workers: int, fn) -> list:
    barrier = threading.Barrier(workers)
    outcomes = []

    def target():
        barrier.wait()
        try:
            outcomes.append(fn())
        except Exception as exc:  # collected and checked by the test
            outcomes.append(type(exc).__name__)
        finally:
            connection.close()

    threads = [threading.Thread(target=target) for _ in range(workers)]
    for t in threads:
        t.start()
    for t in threads:
        t.join()
    return outcomes


def reserve_model(installation, mode="trial"):
    return quota.reserve(installation, mode=mode, source="model").charge


@pytest.mark.django_db(transaction=True)
def test_two_concurrent_reservations_cannot_exceed_the_trial():
    installation, _ = make_installation(trial_used=2)  # one trial left
    outcomes = run_concurrently(2, lambda: reserve_model(installation))
    assert sorted(outcomes) == ["QuotaExhausted", "trial"]
    assert Installation.objects.get(pk=installation.pk).trial_used == 3


@pytest.mark.django_db(transaction=True)
def test_many_concurrent_reservations_take_exactly_three_trials():
    installation, _ = make_installation()
    outcomes = run_concurrently(10, lambda: reserve_model(installation))
    assert outcomes.count("trial") == 3
    assert outcomes.count("QuotaExhausted") == 7
    assert Installation.objects.get(pk=installation.pk).trial_used == 3
    assert VoiceRequest.objects.count() == 3


@pytest.mark.django_db(transaction=True)
def test_account_trial_is_shared_between_devices_under_concurrency():
    account = Account.objects.create(google_sub="s", trial_used=1)
    a, _ = make_installation(account=account)
    b, _ = make_installation(account=account)
    devices = iter([a, b] * 3)
    lock = threading.Lock()

    def next_device():
        with lock:
            return next(devices)

    outcomes = run_concurrently(6, lambda: reserve_model(next_device()))
    assert outcomes.count("trial") == 2
    assert Account.objects.get(pk=account.pk).trial_used == 3


@pytest.mark.django_db(transaction=True)
def test_concurrent_credits_never_go_negative():
    installation, _ = make_installation(trial_used=3, credits=4)
    outcomes = run_concurrently(9, lambda: reserve_model(installation, mode="credits"))
    assert outcomes.count("credit") == 4
    assert Installation.objects.get(pk=installation.pk).credits == 0


@pytest.mark.django_db(transaction=True)
def test_concurrent_reservations_respect_the_monthly_cap(settings):
    settings.VOICE_MONTHLY_CAP_EUR = Decimal("0.02")  # 4 reservations
    installation, _ = make_installation()
    outcomes = run_concurrently(8, lambda: reserve_model(installation, mode="included"))
    assert outcomes.count("cap") == 4
    assert outcomes.count("MonthlyCapReached") == 4
    usage = VoiceMonthlyUsage.objects.get()
    assert usage.reserved_micro_eur == 4 * quota.reservation_micro() <= 20_000


@pytest.mark.django_db
def test_release_gives_everything_back_once():
    installation, _ = make_installation()
    request = quota.reserve(installation, mode="trial", source="model")
    assert quota.release(request) is True
    assert quota.release(request) is False  # idempotent
    installation.refresh_from_db()
    assert installation.trial_used == 0
    assert VoiceGlobalDay.objects.get().reserved_micro_eur == 0


@pytest.mark.django_db
def test_release_of_a_credit_and_of_a_cap_reservation():
    account = Account.objects.create(google_sub="s", trial_used=3, credits=1)
    installation, _ = make_installation(account=account)
    credit = quota.reserve(installation, mode="credits", source="model")
    assert Account.objects.get(pk=account.pk).credits == 0
    quota.release(credit)
    assert Account.objects.get(pk=account.pk).credits == 1
    cap = quota.reserve(installation, mode="included", source="model")
    assert VoiceMonthlyUsage.objects.get().reserved_micro_eur == quota.reservation_micro()
    quota.release(cap)
    assert VoiceMonthlyUsage.objects.get().reserved_micro_eur == 0


@pytest.mark.django_db
def test_settle_moves_the_reservation_to_the_real_cost():
    installation, _ = make_installation()
    request = quota.reserve(installation, mode="included", source="model")
    quota.settle(
        request, model="gemini-2.5-flash-lite", input_tokens=1200, output_tokens=150, cost=168
    )
    quota.settle(request, model="x", input_tokens=1, output_tokens=1, cost=999)  # no double count
    usage = VoiceMonthlyUsage.objects.get()
    assert (usage.reserved_micro_eur, usage.spent_micro_eur, usage.requests) == (0, 168, 1)
    day = VoiceGlobalDay.objects.get()
    assert (day.reserved_micro_eur, day.spent_micro_eur) == (0, 168)
    stored = VoiceRequest.objects.get()
    assert (stored.status, stored.input_tokens, stored.output_tokens) == ("settled", 1200, 150)


def test_cost_of_a_typical_request(settings):
    # Dossier § 3: 1 200 input + 150 output tokens on 2.5 Flash-Lite ~ 0.00018 USD.
    micro = quota.cost_micro_eur("gemini-2.5-flash-lite", 1200, 150)
    assert micro == 168  # 0.00018 USD x 0.93 = 0.0001674 EUR, rounded up to the micro-euro


@pytest.mark.django_db
def test_global_daily_cap_rolls_the_whole_reservation_back(settings):
    settings.VOICE_GLOBAL_DAILY_CAP_EUR = Decimal("0.004")
    installation, _ = make_installation()
    with pytest.raises(quota.GlobalCapReached):
        quota.reserve(installation, mode="trial", source="model")
    installation.refresh_from_db()
    assert installation.trial_used == 0
    assert not VoiceRequest.objects.exists()


@pytest.mark.django_db
def test_monthly_cap_reached_flag():
    installation, _ = make_installation()
    owner = type("O", (), {"installation": installation, "account": None})()
    assert quota.monthly_cap_reached(owner) is False
    VoiceMonthlyUsage.objects.create(
        installation=installation, month=quota._today().replace(day=1), spent_micro_eur=1_999_000
    )
    assert quota.monthly_cap_reached(owner) is True


@pytest.mark.django_db
def test_mode_none_counts_nothing():
    installation, _ = make_installation()
    with pytest.raises(quota.QuotaExhausted):
        quota.reserve(installation, mode="none", source="model")
