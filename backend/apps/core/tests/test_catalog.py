"""The catalog embedded by the API must be the app's catalog (single source of truth)."""

import json
from pathlib import Path

from django.conf import settings

from apps.core.catalog import CATALOG_PATH, get_catalog

APP_CATALOG = Path(settings.BASE_DIR).parent / "app" / "assets" / "catalog.json"


def test_embedded_catalog_matches_app_catalog():
    assert APP_CATALOG.is_file(), f"{APP_CATALOG} missing: the API copy cannot be checked"
    app = json.loads(APP_CATALOG.read_text(encoding="utf-8"))
    api = json.loads(CATALOG_PATH.read_text(encoding="utf-8"))
    assert api == app, (
        "backend/eventide/catalog.json differs from app/assets/catalog.json: "
        "copy the app file (cp app/assets/catalog.json backend/eventide/catalog.json)"
    )


def test_catalog_shape_used_by_the_api(catalog):
    assert catalog.limits["couches_max"] == 6
    assert catalog.limits["essais_assistant_gratuits"] == settings.VOICE_TRIAL_REQUESTS
    for section in ("paysages", "sons", "musiques", "decors"):
        ids = [item["id"] for item in catalog.raw[section]]
        assert len(ids) == len(set(ids)), f"duplicate id in {section}"
        assert all(isinstance(item["gratuit"], bool) for item in catalog.raw[section])
    assert catalog.is_free("paysages", "cascade-foret")
    assert not catalog.is_free("sons", "tonnerre")
    assert get_catalog() is catalog


def test_ambiances_and_event_sounds_follow_contract_section_11(catalog):
    sound_ids = set(catalog.sections["sons"])
    variant_ids = []
    for sound in catalog.raw["sons"]:
        landscape = sound.get("paysage")
        if landscape is not None:
            assert catalog.has("paysages", landscape), sound["id"]
        mode = sound.get("lecture", "boucle")
        assert mode in ("boucle", "evenements"), sound["id"]
        if mode != "evenements":
            assert "variantes" not in sound, sound["id"]
            continue
        variants = sound["variantes"]
        assert len(variants) >= 3 and len(set(variants)) == len(variants), sound["id"]
        variant_ids += variants
        for key in ("intervalle_s", "premier_s"):
            low, high = sound[key]
            assert 0 < low <= high, (sound["id"], key)
    # A variant file never shadows a catalog sound and belongs to one sound only.
    assert len(variant_ids) == len(set(variant_ids))
    assert not sound_ids & set(variant_ids)
    assert catalog.sections["sons"]["tonnerre"]["lecture"] == "evenements"
    # Each landscape with an ambiance plays it first by default.
    for landscape in catalog.raw["paysages"]:
        own = [s["id"] for s in catalog.raw["sons"] if s.get("paysage") == landscape["id"]]
        if own:
            assert landscape["mix"]["sons"][0]["id"] == own[0], landscape["id"]
