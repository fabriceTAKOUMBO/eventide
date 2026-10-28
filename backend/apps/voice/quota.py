"""Voice quotas: free trial, credits, the 2 EUR monthly cap per subscriber, a global daily cap.

Every reservation is an atomic conditional ``UPDATE`` in PostgreSQL, made and committed BEFORE
the model is called (``UPDATE ... SET used = used + 1 WHERE used < limit``): two concurrent
requests can never exceed a limit. The reservation is released if the model call fails, and
settled with the real cost (tokens x price) when it succeeds. A request never settled (process
killed during the call) is released by ``purge_expired`` after a few minutes.
"""

from __future__ import annotations

import logging
from datetime import UTC, timedelta
from decimal import ROUND_CEILING, Decimal

from django.conf import settings
from django.db import transaction
from django.db.models import F, Value
from django.utils import timezone

from apps.accounts.models import Account
from apps.installations.models import Installation

from .models import VoiceGlobalDay, VoiceMonthlyUsage, VoiceRequest

logger = logging.getLogger(__name__)

MICRO = Decimal(1_000_000)


class QuotaExhausted(Exception):
    """402 voice_quota_exhausted: no trial left and no credit."""


class MonthlyCapReached(Exception):
    """402 voice_monthly_cap: the subscriber reached 2 EUR of real cost this month."""


class GlobalCapReached(Exception):
    """All users together reached the daily safety cap: 503 model_unavailable."""


class _Rollback(Exception):
    pass


def to_micro(amount: Decimal) -> int:
    return int((amount * MICRO).to_integral_value(rounding=ROUND_CEILING))


def reservation_micro() -> int:
    return to_micro(settings.VOICE_RESERVATION_EUR)


def cost_micro_eur(model: str, input_tokens: int, output_tokens: int) -> int:
    """Real cost of one call: tokens x price table (USD per million) x USD_EUR_RATE."""
    prices = settings.VOICE_PRICE_TABLE[model]
    usd = (
        Decimal(input_tokens) * prices["input"] + Decimal(output_tokens) * prices["output"]
    ) / MICRO
    return to_micro(usd * settings.USD_EUR_RATE)


def _today():
    return timezone.now().astimezone(UTC).date()


def _usage_owner(installation: Installation, account: Account | None) -> dict:
    if account is not None:
        return {"account": account}
    return {"installation": installation}


def monthly_cap_reached(owner) -> bool:
    month = _today().replace(day=1)
    usage = VoiceMonthlyUsage.objects.filter(
        **_usage_owner(owner.installation, owner.account), month=month
    ).first()
    if usage is None:
        return False
    cap = to_micro(settings.VOICE_MONTHLY_CAP_EUR)
    return usage.spent_micro_eur + usage.reserved_micro_eur + reservation_micro() > cap


def _take_trial(installation: Installation, account: Account | None) -> bool:
    limit = settings.VOICE_TRIAL_REQUESTS
    try:
        with transaction.atomic():
            if not Installation.objects.filter(pk=installation.pk, trial_used__lt=limit).update(
                trial_used=F("trial_used") + 1
            ):
                raise _Rollback
            if account is not None and not Account.objects.filter(
                pk=account.pk, trial_used__lt=limit
            ).update(trial_used=F("trial_used") + 1):
                raise _Rollback
    except _Rollback:
        return False
    return True


def _take_credit(installation: Installation, account: Account | None) -> bool:
    model, pk = (Account, account.pk) if account is not None else (Installation, installation.pk)
    return bool(model.objects.filter(pk=pk, credits__gte=1).update(credits=F("credits") - 1))


def _reserve_monthly(installation: Installation, account: Account | None, month, amount: int):
    usage, _ = VoiceMonthlyUsage.objects.get_or_create(
        **_usage_owner(installation, account), month=month
    )
    cap = to_micro(settings.VOICE_MONTHLY_CAP_EUR)
    if not VoiceMonthlyUsage.objects.filter(
        pk=usage.pk, spent_micro_eur__lte=Value(cap - amount) - F("reserved_micro_eur")
    ).update(reserved_micro_eur=F("reserved_micro_eur") + amount):
        raise MonthlyCapReached


def _reserve_global(day, amount: int) -> None:
    row, _ = VoiceGlobalDay.objects.get_or_create(day=day)
    cap = to_micro(settings.VOICE_GLOBAL_DAILY_CAP_EUR)
    if not VoiceGlobalDay.objects.filter(
        pk=row.pk, spent_micro_eur__lte=Value(cap - amount) - F("reserved_micro_eur")
    ).update(reserved_micro_eur=F("reserved_micro_eur") + amount):
        logger.error("Voice global daily cap reached", extra={"event": "voice_global_cap_reached"})
        raise GlobalCapReached


def reserve(installation: Installation, *, mode: str, source: str) -> VoiceRequest:
    """Count one request before anything else; raises QuotaExhausted, MonthlyCapReached or
    GlobalCapReached. For a local request (``actions_locales``) the count is final at once."""
    model_call = source == VoiceRequest.Source.MODEL
    amount = reservation_micro() if model_call else 0
    today = _today()
    month = today.replace(day=1)
    with transaction.atomic():
        fresh = Installation.objects.select_related("account").get(pk=installation.pk)
        account = fresh.account
        if mode == "included":
            if model_call:
                _reserve_monthly(fresh, account, month, amount)
                charge = VoiceRequest.Charge.CAP
            else:
                # Subscribers resolve local phrases without the API: nothing to count.
                charge = VoiceRequest.Charge.NONE
        elif mode in ("trial", "credits"):
            # Remaining trial first, then credits (free plan and lifetime alike).
            if _take_trial(fresh, account):
                charge = VoiceRequest.Charge.TRIAL
            elif _take_credit(fresh, account):
                charge = VoiceRequest.Charge.CREDIT
            else:
                raise QuotaExhausted
        else:
            raise QuotaExhausted
        if model_call:
            _reserve_global(today, amount)
        return VoiceRequest.objects.create(
            installation=fresh,
            account=account,
            source=source,
            charge=charge,
            status=VoiceRequest.Status.RESERVED if model_call else VoiceRequest.Status.SETTLED,
            month=month,
            day=today,
            reserved_micro_eur=amount,
        )


def settle(
    request: VoiceRequest, *, model: str, input_tokens: int, output_tokens: int, cost: int
) -> None:
    amount = request.reserved_micro_eur
    with transaction.atomic():
        if not VoiceRequest.objects.filter(
            pk=request.pk, status=VoiceRequest.Status.RESERVED
        ).update(
            status=VoiceRequest.Status.SETTLED,
            cost_micro_eur=cost,
            model=model[:64],
            input_tokens=input_tokens,
            output_tokens=output_tokens,
        ):
            return
        if request.charge == VoiceRequest.Charge.CAP:
            VoiceMonthlyUsage.objects.filter(
                **_usage_owner(request.installation, request.account), month=request.month
            ).update(
                reserved_micro_eur=F("reserved_micro_eur") - amount,
                spent_micro_eur=F("spent_micro_eur") + cost,
                requests=F("requests") + 1,
            )
        VoiceGlobalDay.objects.filter(day=request.day).update(
            reserved_micro_eur=F("reserved_micro_eur") - amount,
            spent_micro_eur=F("spent_micro_eur") + cost,
        )


def release(request: VoiceRequest) -> bool:
    """Give back a reservation (model failure). Idempotent."""
    amount = request.reserved_micro_eur
    with transaction.atomic():
        if not VoiceRequest.objects.filter(
            pk=request.pk, status=VoiceRequest.Status.RESERVED
        ).update(status=VoiceRequest.Status.RELEASED):
            return False
        if request.charge == VoiceRequest.Charge.TRIAL:
            Installation.objects.filter(pk=request.installation_id, trial_used__gt=0).update(
                trial_used=F("trial_used") - 1
            )
            if request.account_id is not None:
                Account.objects.filter(pk=request.account_id, trial_used__gt=0).update(
                    trial_used=F("trial_used") - 1
                )
        elif request.charge == VoiceRequest.Charge.CREDIT:
            if request.account_id is not None:
                Account.objects.filter(pk=request.account_id).update(credits=F("credits") + 1)
            else:
                Installation.objects.filter(pk=request.installation_id).update(
                    credits=F("credits") + 1
                )
        elif request.charge == VoiceRequest.Charge.CAP:
            VoiceMonthlyUsage.objects.filter(
                **_usage_owner(request.installation, request.account), month=request.month
            ).update(reserved_micro_eur=F("reserved_micro_eur") - amount)
        if amount:
            VoiceGlobalDay.objects.filter(day=request.day).update(
                reserved_micro_eur=F("reserved_micro_eur") - amount
            )
    return True


def release_stale() -> int:
    limit = timezone.now() - timedelta(minutes=settings.VOICE_STALE_RESERVATION_MINUTES)
    stale = VoiceRequest.objects.select_related("installation", "account").filter(
        status=VoiceRequest.Status.RESERVED, created_at__lt=limit
    )
    return sum(1 for request in stale if release(request))
