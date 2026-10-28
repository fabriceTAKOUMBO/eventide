"""Validation of a scene document (contract § 1) for sharing.

Only the mix is shared (dossier § 6 « Partage »): version, paysage, moment, sons, musique,
decor. ``minuteur``, ``sommeil``, ``sourdine`` (mute: never shared, the recipient hears the mix)
and any unknown field are dropped whatever their shape; a layer at ``niveau`` 0 is dropped (0
removes the element). Premium items are kept: a free recipient sees them locked.
"""

from __future__ import annotations

from typing import Any

from apps.core.catalog import MOMENTS, SCENE_SECTIONS, get_catalog


class InvalidScene(Exception):
    pass


def _level(value: Any) -> int:
    if isinstance(value, bool) or not isinstance(value, int) or not 0 <= value <= 100:
        raise InvalidScene
    return value


def normalise_scene(scene: Any) -> dict:
    catalog = get_catalog()
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
    for key, section in SCENE_SECTIONS.items():
        items = scene.get(key, [])
        if not isinstance(items, list) or len(items) > len(catalog.sections[section]):
            raise InvalidScene
        layer = []
        seen = set()
        for item in items:
            if not isinstance(item, dict) or not catalog.has(section, item.get("id")):
                raise InvalidScene
            if item["id"] in seen:
                raise InvalidScene
            seen.add(item["id"])
            level = _level(item.get("niveau"))
            if level > 0:
                layer.append({"id": item["id"], "niveau": level})
        out[key] = layer
    if len(out["sons"]) + len(out["musique"]) > catalog.limits["couches_max"]:
        raise InvalidScene
    return out
