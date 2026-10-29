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
    for section in ("paysages", "sons", "musiques", "decors"):
        ids = [item["id"] for item in catalog.raw[section]]
        assert len(ids) == len(set(ids)), f"duplicate id in {section}"
        assert all(isinstance(item["gratuit"], bool) for item in catalog.raw[section])
    assert catalog.is_free("paysages", "cascade-foret")
    assert not catalog.is_free("sons", "tonnerre")
    assert get_catalog() is catalog
