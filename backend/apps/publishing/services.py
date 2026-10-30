"""Dashboard actions (contract § 14): create, upload, publish, withdraw, edit; the catalog
revision (contract § 13) and the journal.

Every action is a short transaction on the element row (``SELECT ... FOR UPDATE``); the
revision row is locked and incremented in the same transaction as the change it publishes,
so a reader never sees one without the other. No AWS call is made inside a transaction.
"""

from __future__ import annotations

import logging
import uuid
from datetime import timedelta
from typing import Any

from django.conf import settings
from django.db import transaction
from django.utils import timezone

from . import aws
from .models import AdminLogEntry, CatalogRevision, PublishedItem

logger = logging.getLogger(__name__)

State = PublishedItem.State
Kind = PublishedItem.Kind
Action = AdminLogEntry.Action

# Sources accepted per kind (contract § 14): file extension -> content type of the signed form.
SOURCE_TYPES = {
    Kind.PAYSAGE: {"mp4": "video/mp4", "mov": "video/quicktime", "webm": "video/webm"},
    Kind.SON: {
        "wav": "audio/wav",
        "mp3": "audio/mpeg",
        "ogg": "audio/ogg",
        "m4a": "audio/mp4",
        "flac": "audio/flac",
    },
}
SOURCE_TYPES[Kind.MUSIQUE] = SOURCE_TYPES[Kind.SON]

STALE_DETAIL = "Le traitement n'a pas abouti dans le délai : renvoyez le fichier."
BUSY_DETAIL = "Un autre fichier est en cours de traitement : réessayez dans quelques minutes."

# finish_upload() outcomes.
STARTED, BUSY, CONFLICT = "started", "busy", "conflict"


class ActionRefused(Exception):
    """The action does not apply to the element in its current state."""


class Busy(ActionRefused):
    """A media task is already running (one at a time, ADR hebergement-mutualise § 12.5)."""


def processing_busy() -> bool:
    """An element of this environment is being processed (a processing older than the timeout
    no longer counts: its task is gone)."""
    since = timezone.now() - timedelta(seconds=settings.MEDIA_PROCESSING_TIMEOUT_SECONDS)
    return PublishedItem.objects.filter(
        state=State.TRAITEMENT, processing_started_at__gt=since
    ).exists()


def bump_revision() -> int:
    """Increment the catalog revision under a row lock (call inside ``transaction.atomic``)."""
    row, _ = CatalogRevision.objects.select_for_update().get_or_create(pk=1)
    row.revision += 1
    row.save(update_fields=["revision", "updated_at"])
    return row.revision


def log(account_id: Any, action: str, element: PublishedItem | None = None) -> None:
    """Journal entry. ``account_id`` comes from the dashboard session, whose account is checked
    at each request (``admin_auth``)."""
    AdminLogEntry.objects.create(
        account_id=account_id,
        action=action,
        element=element,
        element_label=element.item_id if element is not None else "",
    )


def create(data: dict[str, Any], account_id: Any) -> PublishedItem:
    with transaction.atomic():
        item = PublishedItem.objects.create(
            kind=data["kind"],
            item_id=data["item_id"],
            nom=data["nom"],
            theme=data.get("theme", ""),
            gratuit=data["gratuit"],
            eclairs=data.get("eclairs", False),
            alias=data.get("alias", []),
            mix=data.get("mix", {}),
            created_by_id=account_id,
        )
        log(account_id, Action.CREATION, item)
    return item


def _locked(pk: Any) -> PublishedItem:
    return PublishedItem.objects.select_for_update().get(pk=pk)


def start_upload(pk: Any, extension: str, account_id: Any) -> dict[str, Any]:
    """Signed POST form for a new source of the element (first file or replacement). The
    element waits in ``envoi`` with a new upload id and a media revision never used before.
    Refused while a media task runs (one at a time): nothing is sent for nothing."""
    item = PublishedItem.objects.get(pk=pk)
    content_type = SOURCE_TYPES[item.kind].get(extension.lower().lstrip("."))
    if content_type is None:
        raise ActionRefused("Type de fichier non accepté.")
    if processing_busy():
        raise Busy(BUSY_DETAIL)
    upload_id = uuid.uuid4()
    form = aws.presigned_post(str(upload_id), content_type)  # local signature, no AWS call
    with transaction.atomic():
        item = _locked(pk)
        replacing = item.media_rev > 0 or item.pending_rev > 0
        item.upload_id = upload_id
        item.pending_rev = max(item.media_rev, item.pending_rev) + 1
        item.pending_has_ambiance = False
        item.pending_info = {}
        item.state = State.ENVOI
        item.detail = ""
        item.processing_started_at = None
        item.save()
        log(account_id, Action.REMPLACEMENT if replacing else Action.ENVOI, item)
    return {"upload_id": str(upload_id), "url": form["url"], "fields": form["fields"]}


def finish_upload(pk: Any, upload_id: str) -> str:
    """The browser finished posting the source: ``envoi`` -> ``traitement`` (once), unless a
    media task already runs: ``BUSY``, the element stays in ``envoi`` with its source and the
    processing can be launched again later. The check and the change are serialised by the
    lock of the revision row, so two administrators never start two tasks."""
    try:
        uid = uuid.UUID(str(upload_id))
    except ValueError:
        return CONFLICT
    with transaction.atomic():
        CatalogRevision.objects.select_for_update().get_or_create(pk=1)
        if not PublishedItem.objects.filter(pk=pk, state=State.ENVOI, upload_id=uid).exists():
            return CONFLICT
        if processing_busy():
            return BUSY
        now = timezone.now()
        PublishedItem.objects.filter(pk=pk, state=State.ENVOI, upload_id=uid).update(
            state=State.TRAITEMENT, detail="", processing_started_at=now, updated_at=now
        )
    return STARTED


def fail(pk: Any, upload_id: Any, detail: str) -> bool:
    """Mark the processing of this upload as failed, unless a newer upload replaced it."""
    return bool(
        PublishedItem.objects.filter(
            pk=pk, upload_id=upload_id, state__in=(State.ENVOI, State.TRAITEMENT)
        ).update(state=State.ECHEC, detail=detail[:200], updated_at=timezone.now())
    )


def expire_stale(item: PublishedItem) -> PublishedItem:
    """A processing that never finished (task stopped, out of memory) is shown as failed."""
    limit = timedelta(seconds=settings.MEDIA_PROCESSING_TIMEOUT_SECONDS)
    started = item.processing_started_at
    stale = item.state == State.TRAITEMENT and started and timezone.now() - started > limit
    if stale and fail(item.pk, item.upload_id, STALE_DETAIL):
        item.refresh_from_db()
    return item


def publish(pk: Any, account_id: Any) -> PublishedItem:
    with transaction.atomic():
        item = _locked(pk)
        if item.state == State.PRET and item.pending_rev >= 1:
            item.media_rev = item.pending_rev
            item.has_ambiance = item.pending_has_ambiance
        elif not (item.state == State.RETIRE and item.media_rev >= 1):
            raise ActionRefused("Rien à publier pour cet élément.")
        item.state = State.PUBLIE
        item.en_catalogue = True
        if item.published_at is None:
            item.published_at = timezone.now()
        item.save()
        bump_revision()
        log(account_id, Action.PUBLICATION, item)
    return item


def withdraw(pk: Any, account_id: Any) -> PublishedItem:
    with transaction.atomic():
        item = _locked(pk)
        if not item.en_catalogue:
            raise ActionRefused("Cet élément n'est pas en ligne.")
        item.en_catalogue = False
        if item.state == State.PUBLIE:
            item.state = State.RETIRE
        item.save()
        bump_revision()
        log(account_id, Action.RETRAIT, item)
    return item


def edit(pk: Any, data: dict[str, Any], account_id: Any) -> PublishedItem:
    """Name, aliases and free / Premium (contract § 14); a new revision when it is online."""
    with transaction.atomic():
        item = _locked(pk)
        item.nom = data["nom"]
        item.alias = data["alias"]
        item.gratuit = data["gratuit"]
        item.save()
        if item.en_catalogue:
            bump_revision()
        log(account_id, Action.MODIFICATION, item)
    return item
