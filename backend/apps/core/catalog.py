"""The closed catalog (``backend/eventide/catalog.json``, copy of ``app/assets/catalog.json``).

A single source of truth shared with the Flutter app: a test fails if the two files differ.
"""

from __future__ import annotations

import json
from dataclasses import dataclass
from functools import cache
from pathlib import Path
from typing import Any

from django.conf import settings

CATALOG_PATH = Path(settings.BASE_DIR) / "eventide" / "catalog.json"

# Scene document list (contract § 1) -> catalog section.
SCENE_SECTIONS = {"sons": "sons", "musique": "musiques", "decor": "decors"}
MOMENTS = ("aube", "jour", "soir", "nuit")


@dataclass(frozen=True)
class Catalog:
    raw: dict[str, Any]
    sections: dict[str, dict[str, dict[str, Any]]]
    limits: dict[str, int]

    def has(self, section: str, item_id: object) -> bool:
        return isinstance(item_id, str) and item_id in self.sections[section]

    def is_free(self, section: str, item_id: str) -> bool:
        return bool(self.sections[section][item_id].get("gratuit"))

    def name(self, section: str, item_id: str) -> str:
        return str(self.sections[section][item_id].get("nom", item_id))


@cache
def get_catalog() -> Catalog:
    raw = json.loads(CATALOG_PATH.read_text(encoding="utf-8"))
    sections = {
        key: {item["id"]: item for item in raw[key]}
        for key in ("paysages", "sons", "musiques", "decors")
    }
    return Catalog(raw=raw, sections=sections, limits=dict(raw["limites"]))
