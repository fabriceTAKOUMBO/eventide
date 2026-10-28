"""Fixed-window rate counters stored in PostgreSQL (no Redis, decision of the product owner)."""

from django.db import models


class RateCounter(models.Model):
    scope = models.CharField(max_length=32)
    key = models.CharField(max_length=64)
    window_start = models.DateTimeField()
    count = models.PositiveIntegerField(default=0)

    class Meta:
        constraints = [
            models.UniqueConstraint(
                fields=["scope", "key", "window_start"], name="ratecounter_unique_window"
            )
        ]
        indexes = [models.Index(fields=["window_start"], name="ratecounter_window_idx")]

    def __str__(self) -> str:
        return f"{self.scope}:{self.window_start:%Y-%m-%dT%H:%M}"
