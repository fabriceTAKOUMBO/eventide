# Voice assistant removed (product owner, 29 October 2026; contract § 7): the account no
# longer holds a trial counter nor credits.

from django.db import migrations


class Migration(migrations.Migration):

    dependencies = [
        ("accounts", "0001_initial"),
    ]

    operations = [
        migrations.RemoveConstraint(
            model_name="account",
            name="account_credits_not_negative",
        ),
        migrations.RemoveField(
            model_name="account",
            name="credits",
        ),
        migrations.RemoveField(
            model_name="account",
            name="trial_used",
        ),
    ]
