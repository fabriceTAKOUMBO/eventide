"""Published catalog (contract § 13) and administration dashboard (contract § 14).

- ``PublishedItem``: a filmed landscape, a sound or a music published from the dashboard, with
  its processing state and the revision of its media files;
- ``CatalogRevision``: one row, the revision of the published catalog (``GET /v1/catalog``);
- ``AdminLogEntry``: the dashboard journal (kept one year, purged by ``purge_expired``).

No e-mail address is ever stored: an administrator is the ``Account`` of their Google ``sub``.
"""

from __future__ import annotations

import uuid

from django.db import models
from django.utils import timezone


class PublishedItem(models.Model):
    class Kind(models.TextChoices):
        PAYSAGE = "paysage", "Paysage filmé"
        SON = "son", "Son"
        MUSIQUE = "musique", "Musique"

    class State(models.TextChoices):
        BROUILLON = "brouillon", "Brouillon"
        ENVOI = "envoi", "Envoi du fichier"
        TRAITEMENT = "traitement", "Traitement"
        PRET = "pret", "Prêt à publier"
        PUBLIE = "publie", "Publié"
        RETIRE = "retire", "Retiré"
        ECHEC = "echec", "Échec"

    id = models.UUIDField(primary_key=True, default=uuid.uuid4, editable=False)
    kind = models.CharField(max_length=8, choices=Kind.choices)
    # Catalog id (``[a-z0-9]+(-[a-z0-9]+)*``, 3 to 40 characters), never reused (contract § 13).
    item_id = models.CharField(max_length=40, unique=True)
    nom = models.CharField(max_length=40)
    theme = models.CharField(max_length=16, blank=True, default="")
    gratuit = models.BooleanField(default=False)
    eclairs = models.BooleanField(default=False)
    alias = models.JSONField(default=list, blank=True)
    # Landscape only: catalog sounds and music added to its default mix, after its ambiance:
    # {"sons": [{"id", "niveau"}], "musique": [{"id", "niveau"}]}.
    mix = models.JSONField(default=dict, blank=True)

    state = models.CharField(max_length=12, choices=State.choices, default=State.BROUILLON)
    # Short French reason shown in the dashboard (failure, silent video...). No personal data.
    detail = models.CharField(max_length=200, blank=True, default="")
    # In the published catalog (``GET /v1/catalog``). Independent of ``state``: a published
    # element whose file is being replaced stays in the catalog with its current files.
    en_catalogue = models.BooleanField(default=False)

    # Files served to the app: ``media_rev`` (0 = never published) and whether the landscape
    # has its ambiance sound ``ambiance-<id>``.
    media_rev = models.PositiveIntegerField(default=0)
    has_ambiance = models.BooleanField(default=False)
    # Files of the current upload: written under ``.v<pending_rev>`` by the processing task.
    # Each upload takes a revision never used before by this element, so a key is written
    # once (no stale CloudFront cache); publishing makes it ``media_rev``.
    pending_rev = models.PositiveIntegerField(default=0)
    pending_has_ambiance = models.BooleanField(default=False)
    # Measurements of the processed files (durations, sizes), for the dashboard.
    pending_info = models.JSONField(default=dict, blank=True)
    # Source of the current upload: ``uploads/<upload_id>/source`` in the content bucket.
    upload_id = models.UUIDField(null=True, blank=True)
    processing_started_at = models.DateTimeField(null=True, blank=True)

    created_by = models.ForeignKey(
        "accounts.Account",
        null=True,
        blank=True,
        on_delete=models.SET_NULL,
        related_name="published_items",
    )
    created_at = models.DateTimeField(auto_now_add=True)
    updated_at = models.DateTimeField(auto_now=True)
    # First publication: order of the published items in the catalog.
    published_at = models.DateTimeField(null=True, blank=True)

    class Meta:
        ordering = ["-created_at"]
        indexes = [
            models.Index(
                fields=["published_at"],
                name="pubitem_listed_idx",
                condition=models.Q(en_catalogue=True),
            )
        ]

    def __str__(self) -> str:
        return f"{self.kind} {self.item_id}"

    @property
    def ambiance_id(self) -> str:
        return f"ambiance-{self.item_id}"


class CatalogRevision(models.Model):
    """Single row (pk 1): incremented with a row lock at each publication, replacement,
    withdrawal or edit of a published element (contract § 13)."""

    id = models.PositiveSmallIntegerField(primary_key=True, default=1, editable=False)
    revision = models.PositiveIntegerField(default=0)
    updated_at = models.DateTimeField(auto_now=True)

    def __str__(self) -> str:
        return f"Catalogue révision {self.revision}"


class AdminLogEntry(models.Model):
    """Dashboard journal (contract § 14): date, administrator account, action, element."""

    class Action(models.TextChoices):
        CONNEXION = "connexion", "Connexion"
        DECONNEXION = "deconnexion", "Déconnexion"
        CREATION = "creation", "Création"
        ENVOI = "envoi", "Envoi du fichier"
        REMPLACEMENT = "remplacement", "Remplacement du fichier"
        PUBLICATION = "publication", "Publication"
        MODIFICATION = "modification", "Modification"
        RETRAIT = "retrait", "Retrait"

    at = models.DateTimeField(default=timezone.now)
    account = models.ForeignKey(
        "accounts.Account",
        null=True,
        blank=True,
        on_delete=models.SET_NULL,
        related_name="admin_log_entries",
    )
    action = models.CharField(max_length=16, choices=Action.choices)
    element = models.ForeignKey(
        PublishedItem,
        null=True,
        blank=True,
        on_delete=models.SET_NULL,
        related_name="log_entries",
    )
    # Catalog id of the element at the time (kept if the element row ever disappears).
    element_label = models.CharField(max_length=40, blank=True, default="")

    class Meta:
        ordering = ["-at"]
        indexes = [models.Index(fields=["at"], name="adminlog_at_idx")]

    def __str__(self) -> str:
        return f"{self.at:%Y-%m-%d %H:%M} {self.action}"
