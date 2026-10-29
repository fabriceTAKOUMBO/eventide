# Credits pack removed with the voice assistant (product owner, 29 October 2026; contract § 6):
# no more `eventide_credits_50` purchases, nothing to consume.

from django.db import migrations, models


def delete_credit_purchases(apps, schema_editor):
    """Credits purchases entitle nothing any more (they stay recorded at Google Play)."""
    Purchase = apps.get_model("entitlements", "Purchase")
    Purchase.objects.using(schema_editor.connection.alias).filter(kind="credits").delete()


class Migration(migrations.Migration):

    dependencies = [
        ("entitlements", "0001_initial"),
    ]

    operations = [
        migrations.RunPython(delete_credit_purchases, migrations.RunPython.noop),
        migrations.RemoveField(
            model_name="purchase",
            name="consumed",
        ),
        migrations.RemoveField(
            model_name="purchase",
            name="credits_granted",
        ),
        migrations.AlterField(
            model_name="purchase",
            name="kind",
            field=models.CharField(
                choices=[("subscription", "Subscription"), ("lifetime", "Lifetime")],
                max_length=16,
            ),
        ),
    ]
