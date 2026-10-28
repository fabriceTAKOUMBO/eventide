"""Rate limits kept in PostgreSQL with an atomic conditional ``UPDATE``.

``hit()`` increments the counter of the current fixed window only while it is below the limit
(``UPDATE ... SET count = count + 1 WHERE count < limit``): two concurrent requests can never
both take the last slot.
"""

from __future__ import annotations

import math
from datetime import datetime, timedelta

from django.db.models import F
from django.utils import timezone

from .errors import RateLimited
from .models import RateCounter

MINUTE = 60
HOUR = 3600
DAY = 86400


def _window_start(now: datetime, seconds: int) -> datetime:
    epoch = math.floor(now.timestamp() / seconds) * seconds
    return datetime.fromtimestamp(epoch, tz=now.tzinfo)


def hit(scope: str, key: str, *, limit: int, window_seconds: int) -> None:
    """Count one request; raise ``RateLimited`` (429) when the window is full."""
    now = timezone.now()
    start = _window_start(now, window_seconds)
    counter, _ = RateCounter.objects.get_or_create(scope=scope, key=key, window_start=start)
    taken = RateCounter.objects.filter(pk=counter.pk, count__lt=limit).update(count=F("count") + 1)
    if not taken:
        retry_after = (start + timedelta(seconds=window_seconds) - now).total_seconds()
        raise RateLimited(retry_after=math.ceil(retry_after))


def purge(older_than: timedelta) -> int:
    deleted, _ = RateCounter.objects.filter(window_start__lt=timezone.now() - older_than).delete()
    return deleted
