# Users page of the dashboard (contract § 14): newest installations first. Built CONCURRENTLY:
# no lock that would block the app's writes on the shared instance while it is built.

from django.contrib.postgres.operations import AddIndexConcurrently
from django.db import migrations, models


class Migration(migrations.Migration):
    atomic = False

    dependencies = [
        ("accounts", "0002_remove_voice_counters"),
        ("installations", "0002_remove_voice_counters"),
    ]

    operations = [
        AddIndexConcurrently(
            model_name="installation",
            index=models.Index(fields=["-created_at"], name="installation_created_idx"),
        ),
    ]
