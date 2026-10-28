from __future__ import annotations

from django.conf import settings

from .base import Router, RouterResult, RouterUnavailable

__all__ = ["Router", "RouterResult", "RouterUnavailable", "get_router"]


def get_router() -> Router:
    if settings.VOICE_ROUTER == "gemini":
        from .gemini import GeminiRouter

        return GeminiRouter()
    if settings.VOICE_ROUTER == "jev":
        from .jev import JevRouter

        return JevRouter()
    from .rules import RulesRouter

    return RulesRouter()
