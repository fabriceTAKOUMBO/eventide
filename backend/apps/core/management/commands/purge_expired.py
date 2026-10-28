"""Daily housekeeping (EventBridge Scheduler): expired counters, stale voice reservations,
voice request details past their retention. Logs one JSON line, no personal data."""

import json
from datetime import timedelta

from django.conf import settings
from django.core.management.base import BaseCommand
from django.utils import timezone

from apps.core import ratelimit
from apps.voice import quota
from apps.voice.models import VoiceGlobalDay, VoiceMonthlyUsage, VoiceRequest


class Command(BaseCommand):
    help = "Purge expired rate counters and voice records, release stale reservations."

    def handle(self, *args, **options):
        now = timezone.now()
        released = quota.release_stale()
        counters = ratelimit.purge(timedelta(days=2))
        requests, _ = (
            VoiceRequest.objects.filter(
                created_at__lt=now - timedelta(days=settings.VOICE_REQUEST_RETENTION_DAYS)
            )
            .exclude(status=VoiceRequest.Status.RESERVED)
            .delete()
        )
        months, _ = VoiceMonthlyUsage.objects.filter(
            month__lt=(now - timedelta(days=400)).date().replace(day=1)
        ).delete()
        days, _ = VoiceGlobalDay.objects.filter(day__lt=(now - timedelta(days=400)).date()).delete()
        self.stdout.write(
            json.dumps(
                {
                    "event": "purge_expired_done",
                    "released_reservations": released,
                    "rate_counters": counters,
                    "voice_requests": requests,
                    "voice_months": months,
                    "voice_days": days,
                }
            )
        )
