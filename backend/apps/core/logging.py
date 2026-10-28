"""Logging helpers: request id on every line, and a scrubber that drops forbidden fields.

The phrase, the transcript and every token are never logged by the code; ``ScrubFilter`` is
a second line of defence if a future ``extra=`` passes one of them by mistake.
"""

from __future__ import annotations

import contextvars
import logging

request_id_var: contextvars.ContextVar[str] = contextvars.ContextVar("request_id", default="-")

FORBIDDEN_FIELDS = frozenset(
    {
        "phrase",
        "phrase_normalisee",
        "transcript",
        "etat",
        "token",
        "id_token",
        "integrity_token",
        "purchase_token",
        "authorization",
        "api_key",
    }
)


class RequestIdFilter(logging.Filter):
    def filter(self, record: logging.LogRecord) -> bool:
        record.request_id = request_id_var.get()
        return True


class ScrubFilter(logging.Filter):
    def filter(self, record: logging.LogRecord) -> bool:
        for name in FORBIDDEN_FIELDS & set(record.__dict__):
            setattr(record, name, "[retiré]")
        return True
