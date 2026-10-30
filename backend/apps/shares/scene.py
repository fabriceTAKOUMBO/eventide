"""Validation of a scene document (contract § 1) for sharing.

Only the mix is shared (dossier § 6 « Partage »): version, paysage, moment, sons, musique,
decor. ``minuteur``, ``sommeil``, ``sourdine`` (mute: never shared, the recipient hears the mix)
and any unknown field are dropped whatever their shape; a layer at ``niveau`` 0 is dropped (0
removes the element). Premium items are kept: a free recipient sees them locked.

Decor (contract § 12): it only applies to a 3D scene (``rendu: 3d``) and only for the ids of its
``decors``. A well-formed decor element that does not apply (a filmed landscape, an id the scene
cannot show, an id no longer in the catalog such as ``eclairs``) is dropped without an error,
like a level 0. A malformed one (not an object, no id, bad level, duplicate) is still refused.

Ids are checked against the published catalog (contract § 13): an element published from the
dashboard is valid, a withdrawn one is unknown.
"""

from __future__ import annotations

from typing import Any

from apps.core.catalog import MOMENTS, SCENE_SECTIONS, Catalog
from apps.publishing.catalog import current_catalog


class InvalidScene(Exception):
    pass


def _level(value: Any) -> int:
    if isinstance(value, bool) or not isinstance(value, int) or not 0 <= value <= 100:
        raise InvalidScene
    return value


def normalise_scene(scene: Any, catalog: Catalog | None = None) -> dict:
    catalog = catalog or current_catalog()
    if not isinstance(scene, dict) or scene.get("version") != 1:
        raise InvalidScene
    if isinstance(scene.get("version"), bool):
        raise InvalidScene
    if not catalog.has("paysages", scene.get("paysage")):
        raise InvalidScene
    if scene.get("moment") not in MOMENTS:
        raise InvalidScene
    out: dict[str, Any] = {
        "version": 1,
        "paysage": scene["paysage"],
        "moment": scene["moment"],
    }
    decors = catalog.decors_of(scene["paysage"])
    for key, section in SCENE_SECTIONS.items():
        items = scene.get(key, [])
        if not isinstance(items, list) or len(items) > len(catalog.sections[section]):
            raise InvalidScene
        layer = []
        seen = set()
        for item in items:
            if not isinstance(item, dict):
                raise InvalidScene
            item_id = item.get("id")
            if key == "decor":
                if not isinstance(item_id, str) or not item_id:
                    raise InvalidScene
            elif not catalog.has(section, item_id):
                raise InvalidScene
            if item_id in seen:
                raise InvalidScene
            seen.add(item_id)
            level = _level(item.get("niveau"))
            if level > 0 and (key != "decor" or item_id in decors):
                layer.append({"id": item_id, "niveau": level})
        out[key] = layer
    if len(out["sons"]) + len(out["musique"]) > catalog.limits["couches_max"]:
        raise InvalidScene
    return out
