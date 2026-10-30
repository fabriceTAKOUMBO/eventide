"""``manage.py process_media <element-uuid>``: the media task (ECS ``ev-<env>-media``, same image).

Processes the element's current upload and records ``pret`` or ``echec``. Exit codes (ADR
hebergement-mutualise § 12.5, a non-zero exit alerts the owner):

- 0: done, a handled failure (a bad or missing file: the element carries the reason), or
  nothing to do (already processed, newer upload): running it twice is harmless;
- non-zero: an unexpected error (the element is marked ``echec`` first when possible), or the
  database unreachable.

Logs one JSON line, no personal data.
"""

import json
import uuid

from django.core.management.base import BaseCommand, CommandError

from apps.publishing.processing import ProcessingCrashed, process_element


class Command(BaseCommand):
    help = "Process the uploaded source of a published element (ffmpeg)."

    def add_arguments(self, parser):
        parser.add_argument("element_id")

    def handle(self, *args, **options):
        try:
            element_id = uuid.UUID(options["element_id"])
        except ValueError as exc:
            raise CommandError("element_id must be a UUID") from exc
        try:
            state = process_element(element_id)
        except ProcessingCrashed as exc:
            self.stdout.write(json.dumps({"event": "process_media_crashed", "state": exc.state}))
            raise CommandError("unexpected error while processing the media") from exc
        self.stdout.write(json.dumps({"event": "process_media_done", "state": state}))
