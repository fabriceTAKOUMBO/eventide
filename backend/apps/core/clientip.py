"""Client address seen through the shared ALB, and its keyed hash (never stored in clear)."""

from __future__ import annotations

from django.conf import settings
from django.http import HttpRequest
from django.utils.crypto import salted_hmac


def client_ip(request: HttpRequest) -> str:
    """The address appended by the last trusted proxy (NUM_PROXIES from the right)."""
    proxies = settings.NUM_PROXIES
    if proxies > 0:
        forwarded = request.META.get("HTTP_X_FORWARDED_FOR", "")
        hops = [h.strip() for h in forwarded.split(",") if h.strip()]
        if len(hops) >= proxies:
            return hops[-proxies]
    return request.META.get("REMOTE_ADDR", "") or "unknown"


def ip_key(request: HttpRequest) -> str:
    """Keyed hash of the client address: rate-limit key without storing the address."""
    return salted_hmac("eventide.ip", client_ip(request), algorithm="sha256").hexdigest()[:32]
