"""Router interface (dossier § 7): « here is a phrase and a state, return a list of actions ».

Implementations: ``rules-only`` (deterministic, free), ``gemini`` (Flash-Lite family, strict
JSON), ``jev`` (reserved). Chosen by configuration (``VOICE_ROUTER``), without a new app version.
"""

from __future__ import annotations

from dataclasses import dataclass, field
from typing import Any, Protocol


class RouterUnavailable(Exception):
    """The model could not answer (network, timeout, HTTP error): the reservation is released
    and the API answers 503 model_unavailable."""


@dataclass(frozen=True)
class RouterResult:
    actions: list[Any]
    model: str = ""
    input_tokens: int = 0
    output_tokens: int = 0
    extra: dict = field(default_factory=dict)


class Router(Protocol):
    name: str

    def route(self, *, phrase: str, state: dict) -> RouterResult: ...
