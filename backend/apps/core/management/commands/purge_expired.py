"""Daily housekeeping (EventBridge Scheduler): expired rate counters. Logs one JSON line, no
personal data."""

import json
from datetime import timedelta

from django.core.management.base import BaseCommand

from apps.core import ratelimit


class Command(BaseCommand):
    help = "Purge expired rate counters."

    def handle(self, *args, **options):
        counters = ratelimit.purge(timedelta(days=2))
        self.stdout.write(json.dumps({"event": "purge_expired_done", "rate_counters": counters}))
