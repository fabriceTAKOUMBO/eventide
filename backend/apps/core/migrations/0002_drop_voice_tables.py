# Voice assistant removed (product owner, 29 October 2026; contract § 7): the `voice` app and
# its models are gone from the code. This drops its three tables from Eventide's own database
# (named one by one, no CASCADE: anything else depending on them makes it fail instead) and
# forgets the app in Django's bookkeeping (content types and their permissions, migration
# records), so that the code before this change, or a later `voice` app (phase 2), finds a
# consistent state and starts again from its `0001_initial`. Only the `eventide` database
# reached by this connection is touched.

from django.db import migrations
from django.db.migrations.recorder import MigrationRecorder

VOICE_TABLES = ("voice_voicerequest", "voice_voicemonthlyusage", "voice_voiceglobalday")


def forget_voice_app(apps, schema_editor):
    alias = schema_editor.connection.alias
    ContentType = apps.get_model("contenttypes", "ContentType")
    # Cascades to the permissions of these content types (auth).
    ContentType.objects.using(alias).filter(app_label="voice").delete()
    MigrationRecorder(schema_editor.connection).migration_qs.filter(app="voice").delete()


class Migration(migrations.Migration):

    dependencies = [
        ("core", "0001_initial"),
        ("contenttypes", "0002_remove_content_type_name"),
        ("auth", "0012_alter_user_first_name_max_length"),
    ]

    operations = [
        migrations.RunSQL(
            [f'DROP TABLE IF EXISTS "{table}";' for table in VOICE_TABLES],
            reverse_sql=migrations.RunSQL.noop,
        ),
        migrations.RunPython(forget_voice_app, migrations.RunPython.noop),
    ]
