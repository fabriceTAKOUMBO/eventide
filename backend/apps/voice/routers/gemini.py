"""``gemini`` router: ``generateContent`` of the Gemini API (REST), strict JSON output.

- model from configuration (``GEMINI_MODEL``, default ``gemini-2.5-flash-lite``);
- ``responseMimeType: application/json`` + ``responseSchema`` (prompt.RESPONSE_SCHEMA);
- the API key travels in the ``x-goog-api-key`` header, never in a URL;
- tokens read from ``usageMetadata`` (thinking tokens are billed as output).

Failure (network, timeout, non-200) -> RouterUnavailable: the reservation is released. A 200
answer whose text is not the expected JSON yields no action (the validator then asks to
rephrase) but its tokens are paid, so they are counted.
"""

from __future__ import annotations

import json
import logging

import requests
from django.conf import settings

from .. import prompt
from .base import RouterResult, RouterUnavailable

logger = logging.getLogger(__name__)

_session = requests.Session()


def _body(phrase: str, state: dict) -> dict:
    generation = {
        "responseMimeType": "application/json",
        "responseSchema": prompt.RESPONSE_SCHEMA,
        "temperature": 0,
        "candidateCount": 1,
        "maxOutputTokens": settings.GEMINI_MAX_OUTPUT_TOKENS,
    }
    if settings.GEMINI_THINKING_BUDGET != "":
        generation["thinkingConfig"] = {"thinkingBudget": int(settings.GEMINI_THINKING_BUDGET)}
    return {
        "systemInstruction": {"parts": [{"text": prompt.system_instruction()}]},
        "contents": [{"role": "user", "parts": [{"text": prompt.user_text(phrase, state)}]}],
        "generationConfig": generation,
    }


def _actions(data: dict) -> list:
    try:
        parts = data["candidates"][0]["content"]["parts"]
        text = "".join(p.get("text", "") for p in parts if isinstance(p, dict))
        decoded = json.loads(text)
    except (KeyError, IndexError, TypeError, ValueError):
        return []
    if not isinstance(decoded, dict):
        return []
    return prompt.to_contract_ops(decoded.get("actions"))


class GeminiRouter:
    name = "gemini"

    def route(self, *, phrase: str, state: dict) -> RouterResult:
        model = settings.GEMINI_MODEL
        url = f"{settings.GEMINI_API_BASE}/models/{model}:generateContent"
        try:
            response = _session.post(
                url,
                json=_body(phrase, state),
                headers={"x-goog-api-key": settings.GEMINI_API_KEY},
                timeout=(3.0, settings.GEMINI_TIMEOUT_SECONDS),
            )
        except (requests.RequestException, OSError) as exc:
            logger.warning("Model unreachable", extra={"event": "model_unavailable"})
            raise RouterUnavailable("network") from exc
        if response.status_code != 200:
            logger.warning(
                "Model error",
                extra={"event": "model_unavailable", "status": response.status_code},
            )
            raise RouterUnavailable(f"http {response.status_code}")
        try:
            data = response.json()
        except ValueError as exc:
            raise RouterUnavailable("body") from exc
        usage = data.get("usageMetadata") or {}
        input_tokens = int(usage.get("promptTokenCount") or 0)
        output_tokens = int(usage.get("candidatesTokenCount") or 0) + int(
            usage.get("thoughtsTokenCount") or 0
        )
        return RouterResult(
            actions=_actions(data),
            model=model,
            input_tokens=input_tokens,
            output_tokens=output_tokens,
        )
