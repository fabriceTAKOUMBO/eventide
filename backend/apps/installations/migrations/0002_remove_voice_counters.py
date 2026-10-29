# Voice assistant removed (product owner, 29 October 2026; contract § 7): the installation no
# longer holds a trial counter nor credits.

from django.db import migrations


class Migration(migrations.Migration):

    dependencies = [
        ("installations", "0001_initial"),
    ]

    operations = [
        migrations.RemoveConstraint(
            model_name="installation",
            name="installation_credits_not_negative",
        ),
        migrations.RemoveField(
            model_name="installation",
            name="credits",
        ),
        migrations.RemoveField(
            model_name="installation",
            name="trial_used",
        ),
    ]
