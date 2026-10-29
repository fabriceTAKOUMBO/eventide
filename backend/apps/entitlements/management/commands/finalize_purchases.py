"""Retry acknowledgement of recent purchases (Google refunds after 3 days).

Scheduled every hour (EventBridge Scheduler, infra/terraform/modules/scheduler).
"""

from django.core.management.base import BaseCommand

from apps.entitlements import purchases


class Command(BaseCommand):
    help = "Acknowledge Google Play purchases not finalised yet."

    def handle(self, *args, **options):
        pending = purchases.pending_finalisation()
        done = sum(1 for p in pending if purchases.finalise(p))
        self.stdout.write(
            f'{{"event":"purchases_finalized","pending":{len(pending)},"done":{done}}}'
        )
