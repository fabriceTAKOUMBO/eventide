"""``jev`` router: reserved for the later test of Jev (TypeSafe AI) behind the same interface."""

from __future__ import annotations

from .base import RouterResult, RouterUnavailable


class JevRouter:
    name = "jev"

    def route(self, *, phrase: str, state: dict) -> RouterResult:
        raise RouterUnavailable("jev router not implemented yet")
