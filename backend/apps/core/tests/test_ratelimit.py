import threading
from datetime import timedelta

import pytest
from django.db import connection
from django.utils import timezone

from apps.core import ratelimit
from apps.core.errors import RateLimited
from apps.core.models import RateCounter


@pytest.mark.django_db
def test_hit_until_the_limit_then_429_with_retry_after():
    for _ in range(3):
        ratelimit.hit("t", "k", limit=3, window_seconds=60)
    with pytest.raises(RateLimited) as exc:
        ratelimit.hit("t", "k", limit=3, window_seconds=60)
    assert 1 <= int(exc.value.headers["Retry-After"]) <= 60
    # Other keys and scopes are independent.
    ratelimit.hit("t", "other", limit=3, window_seconds=60)
    ratelimit.hit("u", "k", limit=3, window_seconds=60)


@pytest.mark.django_db
def test_purge_removes_old_windows():
    RateCounter.objects.create(scope="t", key="k", window_start=timezone.now() - timedelta(days=3))
    ratelimit.hit("t", "k", limit=3, window_seconds=60)
    assert ratelimit.purge(timedelta(days=2)) == 1
    assert RateCounter.objects.count() == 1


@pytest.mark.django_db(transaction=True)
def test_concurrent_hits_never_exceed_the_limit():
    limit, workers = 5, 12
    barrier = threading.Barrier(workers)
    outcomes = []

    def worker():
        barrier.wait()
        try:
            ratelimit.hit("race", "k", limit=limit, window_seconds=3600)
            outcomes.append("ok")
        except RateLimited:
            outcomes.append("limited")
        finally:
            connection.close()

    threads = [threading.Thread(target=worker) for _ in range(workers)]
    for t in threads:
        t.start()
    for t in threads:
        t.join()
    assert outcomes.count("ok") == limit
    assert RateCounter.objects.get(scope="race").count == limit
