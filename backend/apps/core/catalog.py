"""The closed catalog (``backend/eventide/catalog.json``, copy of ``app/assets/catalog.json``).

A single source of truth shared with the Flutter app: a test fails if the two files differ.
``get_catalog()`` is that base catalog; the catalog the API validates against is the published
catalog (base + elements published from the dashboard, contract § 13), built with
``build_catalog()`` by ``apps.publishing.catalog``.
"""

from __future__ import annotations

import json
from dataclasses import dataclass, field
from functools import cache
from pathlib import Path
from typing import Any

from django.conf import settings

CATALOG_PATH = Path(settings.BASE_DIR) / "eventide" / "catalog.json"

# Scene document list (contract § 1) -> catalog section.
SCENE_SECTIONS = {"sons": "sons", "musique": "musiques", "decor": "decors"}
MOMENTS = ("aube", "jour", "soir", "nuit")

# ``paysages[].rendu`` (contract § 12): a filmed landscape (default) or a 3D scene.
RENDER_VIDEO = "video"
RENDER_3D = "3d"
# The 2D landscapes removed on 29 October 2026 (contract § 12): a link or a stored share that
# names one opens on the default free landscape.
RETIRED_LANDSCAPES = frozenset(
    {
        "sous-bois",
        "berge-mousseuse",
        "torrent-montagne",
        "pierres-eau",
        "lisiere-verte",
        "cafe-nuit",
        "aurore-boreale",
        "lune-lac",
    }
)
DEFAULT_LANDSCAPE = "cascade-foret"


@dataclass(frozen=True)
class Catalog:
    raw: dict[str, Any]
    sections: dict[str, dict[str, dict[str, Any]]]
    limits: dict[str, int]
    # Variant file of an event sound (``variantes``, contract § 11) -> that sound's id.
    variants: dict[str, str]
    # Published elements only (contract § 13): section -> id -> ``media_rev``. Their content
    # keys carry ``.v<media_rev>``; base items have none.
    media_revs: dict[str, dict[str, int]] = field(default_factory=dict)

    def has(self, section: str, item_id: object) -> bool:
        return isinstance(item_id, str) and item_id in self.sections[section]

    def sound_of_file(self, file_id: str) -> str | None:
        """Catalog sound played from ``audio/sons/<file_id>.ogg``: the sound itself, or the event
        sound whose variant it is (same free/Premium rule). None for any other id."""
        if file_id in self.sections["sons"]:
            return file_id
        return self.variants.get(file_id)

    def media_rev(self, section: str, item_id: str) -> int | None:
        """``media_rev`` of a published element, None for an item of the base catalog."""
        return self.media_revs.get(section, {}).get(item_id)

    def is_free(self, section: str, item_id: str) -> bool:
        return bool(self.sections[section][item_id].get("gratuit"))

    def name(self, section: str, item_id: str) -> str:
        return str(self.sections[section][item_id].get("nom", item_id))

    def rendering(self, landscape_id: str) -> str:
        """``rendu`` of a landscape (contract § 12): ``video`` (filmed, the default) or ``3d``."""
        return str(self.sections["paysages"][landscape_id].get("rendu", RENDER_VIDEO))

    def decors_of(self, landscape_id: str) -> frozenset[str]:
        """Decor ids that apply to a landscape (contract § 12): the ``decors`` of a ``3d`` scene,
        none for a filmed landscape (its decor cannot be changed)."""
        if self.rendering(landscape_id) != RENDER_3D:
            return frozenset()
        return frozenset(self.sections["paysages"][landscape_id].get("decors", []))

    def landscape_or_default(self, landscape_id: object) -> str | None:
        """The landscape of a stored scene: itself when in the catalog, the default free
        landscape when it was retired (contract § 12), None for any other value."""
        if self.has("paysages", landscape_id):
            return str(landscape_id)
        if landscape_id in RETIRED_LANDSCAPES:
            return DEFAULT_LANDSCAPE
        return None


def build_catalog(
    raw: dict[str, Any], media_revs: dict[str, dict[str, int]] | None = None
) -> Catalog:
    sections = {
        key: {item["id"]: item for item in raw[key]}
        for key in ("paysages", "sons", "musiques", "decors")
    }
    variants = {
        variant: sound["id"] for sound in raw["sons"] for variant in sound.get("variantes", [])
    }
    return Catalog(
        raw=raw,
        sections=sections,
        limits=dict(raw["limites"]),
        variants=variants,
        media_revs=media_revs or {},
    )


@cache
def get_catalog() -> Catalog:
    """The base catalog embedded in the API (never changes while the process runs)."""
    return build_catalog(json.loads(CATALOG_PATH.read_text(encoding="utf-8")))
