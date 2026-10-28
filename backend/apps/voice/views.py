"""``POST /v1/voice`` (contract § 7).

The phrase and the transcript are never logged nor stored: they live only in this request.
"""

from __future__ import annotations

import json
import logging

from django.conf import settings
from django.db import connection
from rest_framework.response import Response
from rest_framework.views import APIView

from apps.core import ratelimit
from apps.core.errors import APIError
from apps.entitlements.services import current_plan, owner_of, voice_body

from . import quota
from .models import VoiceRequest
from .routers import RouterUnavailable, get_router
from .validator import validate_ops

logger = logging.getLogger(__name__)

MAX_PHRASE = 500
MAX_STATE_BYTES = 32 * 1024
MAX_LOCAL_ACTIONS = 50


class VoiceInvalidRequest(APIError):
    status = 422
    code = "invalid_request"
    detail = "Je n'ai pas compris la demande."


class VoiceQuotaExhausted(APIError):
    status = 402
    code = "voice_quota_exhausted"
    detail = "Plus d'essai ni de crédit pour l'assistant."


class VoiceMonthlyCap(APIError):
    status = 402
    code = "voice_monthly_cap"
    detail = "Plafond mensuel de l'assistant atteint."


class ModelUnavailable(APIError):
    status = 503
    code = "model_unavailable"
    detail = "Assistant momentanément indisponible."


def _parse(data: object) -> tuple[str, dict, list | None]:
    if not isinstance(data, dict):
        raise VoiceInvalidRequest()
    phrase = data.get("phrase")
    normalised = data.get("phrase_normalisee", phrase)
    state = data.get("etat", {})
    local = data.get("actions_locales")
    for text in (phrase, normalised):
        if not isinstance(text, str) or not text.strip() or len(text) > MAX_PHRASE:
            raise VoiceInvalidRequest()
    if not isinstance(state, dict):
        raise VoiceInvalidRequest()
    if len(json.dumps(state, ensure_ascii=False).encode("utf-8")) > MAX_STATE_BYTES:
        raise VoiceInvalidRequest()
    if local is not None and (not isinstance(local, list) or len(local) > MAX_LOCAL_ACTIONS):
        raise VoiceInvalidRequest()
    return normalised.strip(), state, local


class VoiceView(APIView):
    def post(self, request):
        installation = request.user
        phrase, state, local = _parse(request.data)
        key = str(installation.pk)
        ratelimit.hit(
            "voice_min", key, limit=settings.VOICE_RATE_PER_MINUTE, window_seconds=ratelimit.MINUTE
        )
        ratelimit.hit(
            "voice_day", key, limit=settings.VOICE_RATE_PER_DAY, window_seconds=ratelimit.DAY
        )
        owner = owner_of(installation)
        plan = current_plan(owner)
        mode = plan.voice_mode

        if local is not None:
            if mode != "none":
                self._reserve(installation, mode, VoiceRequest.Source.LOCAL)
            return self._answer(installation, plan, validate_ops(local, plan.plan), "local")

        if mode == "none":
            raise ModelUnavailable()
        reservation = self._reserve(installation, mode, VoiceRequest.Source.MODEL)
        # The reservation is committed: give the pooled connection back while the model thinks
        # (bounds the connections of a task, see DB_POOL_MAX_SIZE).
        if settings.DB_POOL_MAX_SIZE and not connection.in_atomic_block:
            connection.close()
        try:
            result = get_router().route(phrase=phrase, state=state)
        except RouterUnavailable as exc:
            quota.release(reservation)
            raise ModelUnavailable() from exc
        except Exception:
            quota.release(reservation)
            raise
        cost = 0
        if result.model in settings.VOICE_PRICE_TABLE:
            cost = quota.cost_micro_eur(result.model, result.input_tokens, result.output_tokens)
        quota.settle(
            reservation,
            model=result.model,
            input_tokens=result.input_tokens,
            output_tokens=result.output_tokens,
            cost=cost,
        )
        actions = validate_ops(result.actions, plan.plan)
        logger.info(
            "Voice request answered",
            extra={
                "event": "voice_answered",
                "router": settings.VOICE_ROUTER,
                "model": result.model,
                "input_tokens": result.input_tokens,
                "output_tokens": result.output_tokens,
                "cost_micro_eur": cost,
                "actions": len(actions),
                "charge": reservation.charge,
            },
        )
        return self._answer(installation, plan, actions, "model")

    @staticmethod
    def _reserve(installation, mode: str, source: str) -> VoiceRequest:
        try:
            return quota.reserve(installation, mode=mode, source=source)
        except quota.QuotaExhausted as exc:
            raise VoiceQuotaExhausted() from exc
        except quota.MonthlyCapReached as exc:
            raise VoiceMonthlyCap() from exc
        except quota.GlobalCapReached as exc:
            raise ModelUnavailable() from exc

    @staticmethod
    def _answer(installation, plan, actions: list, source: str) -> Response:
        voice = voice_body(owner_of(installation), plan)
        return Response({"actions": actions, "source": source, "voice": voice})
