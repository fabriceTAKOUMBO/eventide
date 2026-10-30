# The single row of the catalog revision (contract § 13): 0 while nothing is published.

from django.db import migrations


def create_row(apps, schema_editor):
    CatalogRevision = apps.get_model("publishing", "CatalogRevision")
    CatalogRevision.objects.get_or_create(pk=1, defaults={"revision": 0})


class Migration(migrations.Migration):
    dependencies = [
        ("publishing", "0001_initial"),
    ]

    operations = [
        migrations.RunPython(create_row, migrations.RunPython.noop),
    ]
