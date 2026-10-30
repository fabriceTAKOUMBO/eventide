"""Daily housekeeping (EventBridge Scheduler): expired rate counters, dashboard journal entries
older than a year (contract § 14) and expired dashboard sessions. Logs one JSON line, no
personal data."""

import json
from datetime import timedelta

from django.contrib.sessions.models import Session
from django.core.management.base import BaseCommand
from django.utils import timezone

from apps.core import ratelimit
from apps.publishing.models import AdminLogEntry

ADMIN_LOG_RETENTION = timedelta(days=365)


class Command(BaseCommand):
    help = "Purge expired rate counters, old dashboard journal entries and expired sessions."

    def handle(self, *args, **options):
        now = timezone.now()
        counters = ratelimit.purge(timedelta(days=2))
        journal, _ = AdminLogEntry.objects.filter(at__lt=now - ADMIN_LOG_RETENTION).delete()
        sessions, _ = Session.objects.filter(expire_date__lt=now).delete()
        self.stdout.write(
            json.dumps(
                {
                    "event": "purge_expired_done",
                    "rate_counters": counters,
                    "admin_log_entries": journal,
                    "sessions": sessions,
                }
            )
        )
