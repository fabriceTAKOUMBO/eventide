"""Published catalog (contract § 13): the base catalog plus the elements published from the
dashboard, and the ``distant`` lists (media on the server).

Cached per process and keyed by the catalog revision: each call costs one ``SELECT`` of the
revision (primary key); the published elements are read again only when it changed (one more
query). The revision is read before the elements, so a publication committed in between is
never cached under the newer revision with older elements.
"""

from __future__ import annotations

import copy
import json
import logging
import threading
from dataclasses import dataclass
from pathlib import Path
from typing import Any

from django.conf import settings

from apps.core.catalog import RETIRED_LANDSCAPES, Catalog, build_catalog, get_catalog

from .models import CatalogRevision, PublishedItem

logger = logging.getLogger(__name__)

# Base ``distant`` lists: copy of ``app/assets/landscapes/remote.json`` (one source: a test
# fails if the two files differ, like the catalog).
BASE_DISTANT_PATH = Path(settings.BASE_DIR) / "eventide" / "remote.json"
DISTANT_SECTIONS = ("videos", "images", "sons", "musiques")
AMBIANCE_LEVEL = 60
AMBIANCE_PREFIX = "ambiance-"
SECTION_OF_KIND = {
    PublishedItem.Kind.PAYSAGE: "paysages",
    PublishedItem.Kind.SON: "sons",
    PublishedItem.Kind.MUSIQUE: "musiques",
}


@dataclass(frozen=True)
class PublishedCatalog:
    revision: int
    catalog: Catalog
    distant: dict[str, Any]
    # Body of ``GET /v1/catalog`` (compact JSON, UTF-8).
    body: bytes

    @property
    def etag(self) -> str:
        return f'"{self.revision}"'


_lock = threading.Lock()
_cached: PublishedCatalog | None = None
_base_distant: dict[str, Any] | None = None


def base_distant() -> dict[str, Any]:
    global _base_distant
    if _base_distant is None:
        _base_distant = json.loads(BASE_DISTANT_PATH.read_text(encoding="utf-8"))
    return _base_distant


def current_revision() -> int:
    value = CatalogRevision.objects.filter(pk=1).values_list("revision", flat=True).first()
    return int(value or 0)


def ambiance_name(nom: str) -> str:
    return f"Ambiance — {nom}"


def media_keys(kind: str, item_id: str, rev: int, has_ambiance: bool) -> dict[str, str]:
    """Content keys of an element's files at a media revision (contract § 13)."""
    if kind == PublishedItem.Kind.PAYSAGE:
        keys = {
            "video": f"videos/paysages/{item_id}.v{rev}.mp4",
            "image": f"images/paysages/{item_id}.v{rev}.jpg",
        }
        if has_ambiance:
            keys["ambiance"] = f"audio/sons/{AMBIANCE_PREFIX}{item_id}.v{rev}.ogg"
        return keys
    folder = "sons" if kind == PublishedItem.Kind.SON else "musiques"
    return {"audio": f"audio/{folder}/{item_id}.v{rev}.ogg"}


def base_ids() -> frozenset[str]:
    """Every id the base catalog uses (all sections, event-sound variants, themes) and the
    retired 2D landscapes: a published id never takes one of them (contract § 13)."""
    base = get_catalog()
    ids = set(RETIRED_LANDSCAPES) | set(base.variants)
    for section in ("paysages", "sons", "musiques", "decors"):
        ids |= set(base.sections[section])
    ids |= {theme["id"] for theme in base.raw.get("themes", [])}
    return frozenset(ids)


def _layer(entries: Any, allowed: set[str]) -> list[dict[str, Any]]:
    out, seen = [], set()
    for entry in entries if isinstance(entries, list) else []:
        if not isinstance(entry, dict):
            continue
        item_id, level = entry.get("id"), entry.get("niveau")
        valid_level = isinstance(level, int) and not isinstance(level, bool) and 0 < level <= 100
        if item_id in allowed and item_id not in seen and valid_level:
            out.append({"id": item_id, "niveau": level})
            seen.add(item_id)
    return out


def merge(revision: int, items: list[PublishedItem]) -> PublishedCatalog:
    """Base catalog + published elements, in the exact format of ``catalog.json``."""
    base = get_catalog()
    raw = copy.deepcopy(base.raw)
    distant = copy.deepcopy(base_distant())
    reserved = base_ids()
    media_revs: dict[str, dict[str, int]] = {"paysages": {}, "sons": {}, "musiques": {}}
    landscapes, sounds, musics, ambiances = [], [], [], []
    for item in items:
        clash = item.item_id in reserved or (
            item.kind == PublishedItem.Kind.PAYSAGE and item.ambiance_id in reserved
        )
        if clash or item.media_rev < 1:
            logger.warning("Published element skipped", extra={"event": "catalog_item_skipped"})
            continue
        common = {"nom": item.nom, "gratuit": item.gratuit}
        if item.kind == PublishedItem.Kind.PAYSAGE:
            landscapes.append(item)
            if item.has_ambiance:
                ambiances.append(
                    {
                        "id": item.ambiance_id,
                        "nom": ambiance_name(item.nom),
                        "gratuit": item.gratuit,
                        "paysage": item.item_id,
                        "alias": [],
                        "media_rev": item.media_rev,
                    }
                )
                media_revs["sons"][item.ambiance_id] = item.media_rev
                distant["sons"].append(item.ambiance_id)
            media_revs["paysages"][item.item_id] = item.media_rev
            distant["videos"].append(item.item_id)
            distant["images"].append(item.item_id)
        elif item.kind == PublishedItem.Kind.SON:
            sounds.append(
                {
                    "id": item.item_id,
                    **common,
                    "alias": list(item.alias),
                    "media_rev": item.media_rev,
                }
            )
            media_revs["sons"][item.item_id] = item.media_rev
            distant["sons"].append(item.item_id)
        else:
            musics.append(
                {
                    "id": item.item_id,
                    **common,
                    "alias": list(item.alias),
                    "media_rev": item.media_rev,
                }
            )
            media_revs["musiques"][item.item_id] = item.media_rev
            distant["musiques"].append(item.item_id)
    raw["sons"].extend(sounds + ambiances)
    raw["musiques"].extend(musics)
    # A landscape's default mix only names loop sounds of the published catalog that belong to
    # no other landscape, and music of the catalog; its own ambiance first (contract § 11).
    loops = {
        s["id"]
        for s in raw["sons"]
        if "paysage" not in s and s.get("lecture", "boucle") in ("boucle", "evenements")
    }
    music_ids = {m["id"] for m in raw["musiques"]}
    max_layers = base.limits["couches_max"]
    for item in landscapes:
        mix = item.mix if isinstance(item.mix, dict) else {}
        layer_sons = _layer(mix.get("sons"), loops)
        if item.has_ambiance:
            layer_sons.insert(0, {"id": item.ambiance_id, "niveau": AMBIANCE_LEVEL})
        layer_music = _layer(mix.get("musique"), music_ids)
        layer_sons = layer_sons[:max_layers]
        layer_music = layer_music[: max(0, max_layers - len(layer_sons))]
        entry: dict[str, Any] = {
            "id": item.item_id,
            "theme": item.theme,
            "nom": item.nom,
            "gratuit": item.gratuit,
            "rendu": "video",
        }
        if item.eclairs:
            entry["eclairs"] = True
        entry["alias"] = list(item.alias)
        entry["mix"] = {"sons": layer_sons, "musique": layer_music, "decor": []}
        entry["media_rev"] = item.media_rev
        raw["paysages"].append(entry)
    for section in DISTANT_SECTIONS:
        distant[section] = sorted(set(distant.get(section, [])))
    body = json.dumps(
        {"revision": revision, "catalog": raw, "distant": distant},
        ensure_ascii=False,
        separators=(",", ":"),
    ).encode("utf-8")
    return PublishedCatalog(
        revision=revision,
        catalog=build_catalog(raw, media_revs),
        distant=distant,
        body=body,
    )


def published_catalog() -> PublishedCatalog:
    """The current published catalog (one cheap query when the cache is up to date)."""
    global _cached
    revision = current_revision()
    cached = _cached
    if cached is not None and cached.revision == revision:
        return cached
    for _ in range(3):
        items = list(
            PublishedItem.objects.filter(en_catalogue=True, media_rev__gte=1).order_by(
                "published_at", "item_id"
            )
        )
        after = current_revision()
        if after == revision:
            break
        revision = after
    built = merge(revision, items)
    with _lock:
        if _cached is None or _cached.revision <= built.revision:
            _cached = built
    return built


def current_catalog() -> Catalog:
    return published_catalog().catalog


def reset_cache_for_tests() -> None:
    global _cached
    with _lock:
        _cached = None
