"""Processing of an uploaded source (contract § 14, step 3): start it, and run it.

``start(element)`` runs the media task (``ecs:RunTask``) once the browser has posted the
source. Without a configured task, it runs in a background thread when ``DEBUG`` is on
(development), and fails clearly otherwise.

``process_element(id)`` (``manage.py process_media <id>``) is light on the shared database:
one short transaction reads the element, the connection is closed during the ffmpeg work, and
one short transaction writes the result. It is idempotent: an element that is no longer
being processed for this upload is left as it is, and the output keys depend only on the
upload (a second run writes the same files).
"""

from __future__ import annotations

import logging
import tempfile
import threading
import uuid
from dataclasses import dataclass
from pathlib import Path
from typing import Any

from django.conf import settings
from django.db import close_old_connections, connection, transaction
from django.utils import timezone

from . import aws, media, services, storage
from .catalog import ambiance_name, media_keys
from .models import PublishedItem

logger = logging.getLogger(__name__)

State = PublishedItem.State
Kind = PublishedItem.Kind

VIDEO_PARAMS = media.VideoParams()
AUDIO_PARAMS = media.AudioParams()

NOT_STARTED = "Le traitement n'a pas pu démarrer : réessayez plus tard."
NOT_CONFIGURED = "Le traitement n'est pas configuré sur ce serveur."
SOURCE_MISSING = "Fichier source introuvable : renvoyez-le."
SOURCE_TOO_LARGE = "Fichier source trop lourd (300 Mo au plus)."
INTERNAL = "Erreur interne pendant le traitement : réessayez ou changez de fichier."
SILENT_LANDSCAPE = "Vidéo sans son utilisable : paysage sans ambiance."
UNUSABLE_SOUNDTRACK = "Le son de la vidéo n'a pas pu être traité : paysage sans ambiance."


@dataclass(frozen=True)
class Job:
    element_id: uuid.UUID
    kind: str
    item_id: str
    nom: str
    upload_id: uuid.UUID
    rev: int


@dataclass(frozen=True)
class Outcome:
    has_ambiance: bool
    detail: str
    info: dict[str, Any]


def start(item: PublishedItem) -> None:
    """Start the processing of the element's current upload (state ``traitement``)."""
    if aws.media_task_configured():
        try:
            aws.run_media_task(str(item.pk))
        except Exception:
            logger.exception("Media task start failed", extra={"event": "media_task_error"})
            services.fail(item.pk, item.upload_id, NOT_STARTED)
        return
    if settings.DEBUG:
        thread = threading.Thread(
            target=_run_in_thread, args=(item.pk,), name="process-media", daemon=True
        )
        thread.start()
        return
    services.fail(item.pk, item.upload_id, NOT_CONFIGURED)


def _run_in_thread(element_id: Any) -> None:  # pragma: no cover - development only
    try:
        process_element(element_id)
    except ProcessingCrashed:
        pass  # already logged and recorded as echec
    finally:
        connection.close()


def _claim(element_id: Any) -> Job | None:
    with transaction.atomic():
        item = PublishedItem.objects.filter(pk=element_id).first()
        if item is None or item.state != State.TRAITEMENT or item.upload_id is None:
            return None
        return Job(
            element_id=item.pk,
            kind=item.kind,
            item_id=item.item_id,
            nom=item.nom,
            upload_id=item.upload_id,
            rev=item.pending_rev,
        )


def _release_db() -> None:
    """No database connection held during the ffmpeg work (shared instance)."""
    connection.close()
    close_pool = getattr(connection, "close_pool", None)
    if close_pool is not None and connection.settings_dict.get("OPTIONS", {}).get("pool"):
        close_pool()


def run_job(job: Job, store: storage.MediaStorage, workdir: Path) -> Outcome:
    source = workdir / "source"
    store.fetch_source(str(job.upload_id), source, settings.UPLOAD_MAX_BYTES)
    info = media.probe(source)
    keys = media_keys(job.kind, job.item_id, job.rev, has_ambiance=True)
    uploads: list[tuple[str, Path]] = []
    details: dict[str, Any] = {}
    detail = ""
    has_ambiance = False
    if job.kind == Kind.PAYSAGE:
        video = media.make_video(source, info, workdir, VIDEO_PARAMS)
        uploads += [(keys["video"], video.path), (keys["image"], video.poster)]
        details["video"] = {
            "secondes": video.seconds,
            "octets": video.bytes,
            "images": video.frames,
            "ips": video.fps,
            "crf": video.crf,
        }
        details["image"] = {"octets": video.poster_bytes}
        try:
            audio = media.make_audio(
                source, info, workdir / "ambiance.ogg", ambiance_name(job.nom), AUDIO_PARAMS
            )
        except media.NoUsableAudio:
            detail = SILENT_LANDSCAPE
        except media.MediaError:
            # The picture is fine: the landscape is still usable, without its ambiance.
            logger.warning("Ambiance not made", extra={"event": "process_media_no_ambiance"})
            detail = UNUSABLE_SOUNDTRACK
        else:
            has_ambiance = True
            uploads.append((keys["ambiance"], audio.path))
            details["ambiance"] = _audio_info(audio)
    else:
        try:
            audio = media.make_audio(source, info, workdir / "audio.ogg", job.nom, AUDIO_PARAMS)
        except media.NoUsableAudio as exc:
            raise media.MediaError(exc.reason) from exc
        uploads.append((keys["audio"], audio.path))
        details["audio"] = _audio_info(audio)
    for key, path in uploads:
        store.put(key, path)
    return Outcome(has_ambiance=has_ambiance, detail=detail, info=details)


def _audio_info(audio: media.AudioResult) -> dict[str, Any]:
    return {
        "secondes": audio.seconds,
        "boucle_secondes": audio.loop_seconds,
        "octets": audio.bytes,
        "lufs": audio.lufs,
    }


class ProcessingCrashed(Exception):
    """An unexpected error (a bug, not a bad file): the element is marked ``echec`` all the
    same, and the media task exits non-zero so that the owner is alerted."""

    def __init__(self, state: str):
        super().__init__(state)
        self.state = state


def process_element(element_id: Any) -> str:
    """Process the current upload of an element; returns its state afterwards. A bad file is
    a handled failure (``echec`` with its reason); an unexpected error raises
    ``ProcessingCrashed`` once the failure is recorded."""
    close_old_connections()
    job = _claim(element_id)
    if job is None:
        item = PublishedItem.objects.filter(pk=element_id).only("state").first()
        state = item.state if item else "absent"
        logger.info("Nothing to process", extra={"event": "process_media_skip", "state": state})
        return state
    # The ev_app role closes sessions idle for 15 minutes: no connection during ffmpeg.
    _release_db()
    outcome: Outcome | None = None
    failure = ""
    crashed = False
    try:
        store = storage.get_storage()
        with tempfile.TemporaryDirectory(prefix="ev-media-") as tmp:
            outcome = run_job(job, store, Path(tmp))
    except storage.StorageNotConfigured:
        failure = NOT_CONFIGURED
    except storage.SourceMissing:
        failure = SOURCE_MISSING
    except storage.SourceTooLarge:
        failure = SOURCE_TOO_LARGE
    except media.MediaError as exc:
        failure = exc.reason
    except Exception:
        logger.exception("Media processing failed", extra={"event": "process_media_error"})
        failure = INTERNAL
        crashed = True
    # Reconnect for the result (a new connection, the old one was closed).
    close_old_connections()
    if outcome is None:
        services.fail(job.element_id, job.upload_id, failure)
    else:
        with transaction.atomic():
            PublishedItem.objects.filter(
                pk=job.element_id, state=State.TRAITEMENT, upload_id=job.upload_id
            ).update(
                state=State.PRET,
                detail=outcome.detail,
                pending_has_ambiance=outcome.has_ambiance,
                pending_info=outcome.info,
                updated_at=timezone.now(),
            )
    item = PublishedItem.objects.filter(pk=job.element_id).only("state").first()
    state = item.state if item else "absent"
    logger.info("Media processed", extra={"event": "process_media_done", "state": state})
    if crashed:
        raise ProcessingCrashed(state)
    return state
