"""Published catalog (contract § 13): merge, revision, ETag / 304, cache, distant lists."""

import json
from pathlib import Path

import pytest
from django.conf import settings
from django.db import connection
from django.test.utils import CaptureQueriesContext

from apps.core.catalog import CATALOG_PATH
from apps.publishing import services
from apps.publishing.catalog import BASE_DISTANT_PATH, published_catalog
from apps.publishing.models import PublishedItem
from conftest import client_for, make_installation

from .conftest import publish_item

APP_REMOTE = Path(settings.BASE_DIR).parent / "app" / "assets" / "landscapes" / "remote.json"
BASE = json.loads(CATALOG_PATH.read_text(encoding="utf-8"))
BASE_DISTANT = json.loads(BASE_DISTANT_PATH.read_text(encoding="utf-8"))
Kind = PublishedItem.Kind


def test_embedded_distant_lists_match_the_app_remote_manifest():
    """One source: backend/eventide/remote.json is the copy of the app's remote.json."""
    assert APP_REMOTE.is_file(), f"{APP_REMOTE} missing: the API copy cannot be checked"
    app_remote = json.loads(APP_REMOTE.read_text(encoding="utf-8"))
    assert app_remote == BASE_DISTANT, (
        "backend/eventide/remote.json differs from app/assets/landscapes/remote.json: copy it "
        "(cp app/assets/landscapes/remote.json backend/eventide/remote.json)"
    )


@pytest.mark.django_db
def test_nothing_published_is_the_base_catalog_at_revision_0(api):
    response = api.get("/v1/catalog")
    assert response.status_code == 200
    assert response["ETag"] == '"0"'
    assert response["Cache-Control"] == "private, no-cache"
    assert response["Content-Type"].startswith("application/json")
    body = response.json()
    assert body == {"revision": 0, "catalog": BASE, "distant": BASE_DISTANT}
    # The v1 API never gets a session cookie (the dashboard's cookie is scoped to /tableau/).
    assert "Set-Cookie" not in response
    assert "Cookie" not in response.get("Vary", "")


@pytest.mark.django_db
@pytest.mark.parametrize("header", ['"0"', 'W/"0"', '"5", "0"', "*"])
def test_if_none_match_with_the_current_revision_is_304(api, header):
    response = api.get("/v1/catalog", HTTP_IF_NONE_MATCH=header)
    assert response.status_code == 304
    assert response.content == b""
    assert response["ETag"] == '"0"'
    assert response["Cache-Control"] == "private, no-cache"


@pytest.mark.django_db
def test_an_older_revision_gets_the_new_catalog(api):
    publish_item()
    response = api.get("/v1/catalog", HTTP_IF_NONE_MATCH='"0"')
    assert response.status_code == 200
    assert response["ETag"] == '"1"'
    assert response.json()["revision"] == 1
    assert api.get("/v1/catalog", HTTP_IF_NONE_MATCH='"1"').status_code == 304


@pytest.mark.django_db
def test_catalog_requires_an_installation_token(client):
    response = client.get("/v1/catalog")
    assert response.status_code == 401
    assert response.json()["error"] == "unauthorized"


@pytest.mark.django_db
def test_catalog_rate_limit(api, settings):
    settings.RATE_CATALOG_PER_HOUR = 2
    assert api.get("/v1/catalog").status_code == 200
    assert api.get("/v1/catalog", HTTP_IF_NONE_MATCH='"0"').status_code == 304
    response = api.get("/v1/catalog")
    assert response.status_code == 429
    assert int(response["Retry-After"]) >= 1


@pytest.mark.django_db
def test_published_elements_join_the_catalog_in_the_base_format(api):
    sound = publish_item(Kind.SON, "vent-doux", nom="Vent doux", alias=["brise douce"])
    music = publish_item(Kind.MUSIQUE, "piano-nuit", nom="Piano de nuit", gratuit=False)
    landscape = publish_item(
        Kind.PAYSAGE,
        "lac-brume",
        nom="Lac dans la brume",
        gratuit=False,
        theme="nature",
        eclairs=True,
        alias=["lac"],
        has_ambiance=True,
        media_rev=3,
        mix={
            "sons": [
                {"id": "vent-doux", "niveau": 35},
                {"id": "inconnu", "niveau": 20},  # dropped: not in the catalog
                {"id": "ambiance-pluie-ville", "niveau": 20},  # dropped: another landscape's
            ],
            "musique": [{"id": "piano-nuit", "niveau": 20}],
        },
    )
    body = api.get("/v1/catalog").json()
    assert body["revision"] == 3
    catalog = body["catalog"]
    assert catalog["version"] == 1
    assert catalog["themes"] == BASE["themes"] and catalog["limites"] == BASE["limites"]
    assert catalog["decors"] == BASE["decors"]
    # Every base item is still there, unchanged and first.
    for section in ("paysages", "sons", "musiques"):
        assert catalog[section][: len(BASE[section])] == BASE[section]
    assert catalog["paysages"][-1] == {
        "id": "lac-brume",
        "theme": "nature",
        "nom": "Lac dans la brume",
        "gratuit": False,
        "rendu": "video",
        "eclairs": True,
        "alias": ["lac"],
        "mix": {
            "sons": [
                {"id": "ambiance-lac-brume", "niveau": 60},
                {"id": "vent-doux", "niveau": 35},
            ],
            "musique": [{"id": "piano-nuit", "niveau": 20}],
            "decor": [],
        },
        "media_rev": 3,
    }
    assert catalog["sons"][len(BASE["sons"]) :] == [
        {
            "id": "vent-doux",
            "nom": "Vent doux",
            "gratuit": True,
            "alias": ["brise douce"],
            "media_rev": 1,
        },
        {
            "id": "ambiance-lac-brume",
            "nom": "Ambiance — Lac dans la brume",
            "gratuit": False,
            "paysage": "lac-brume",
            "alias": [],
            "media_rev": 3,
        },
    ]
    assert catalog["musiques"][-1] == {
        "id": "piano-nuit",
        "nom": "Piano de nuit",
        "gratuit": False,
        "alias": [],
        "media_rev": 1,
    }
    distant = body["distant"]
    assert distant["version"] == 1
    assert "lac-brume" in distant["videos"] and "lac-brume" in distant["images"]
    assert {"ambiance-lac-brume", "vent-doux"} <= set(distant["sons"])
    assert "piano-nuit" in distant["musiques"]
    for section in ("videos", "images", "sons", "musiques"):
        assert set(BASE_DISTANT[section]) <= set(distant[section])
        assert distant[section] == sorted(set(distant[section]))
    assert sound.pk and music.pk and landscape.pk


@pytest.mark.django_db
def test_a_landscape_without_ambiance_has_no_ambiance_sound(api):
    publish_item(Kind.PAYSAGE, "dunes", nom="Dunes", theme="nature", has_ambiance=False)
    body = api.get("/v1/catalog").json()
    landscape = body["catalog"]["paysages"][-1]
    assert landscape["id"] == "dunes" and "eclairs" not in landscape
    assert landscape["mix"] == {"sons": [], "musique": [], "decor": []}
    assert not any(s["id"] == "ambiance-dunes" for s in body["catalog"]["sons"])
    assert "ambiance-dunes" not in body["distant"]["sons"]


@pytest.mark.django_db
def test_withdrawn_and_unpublished_elements_are_not_in_the_catalog(api, admin_account):
    sound = publish_item(Kind.SON, "vent-doux")
    publish_item(Kind.SON, "jamais-en-ligne", en_catalogue=False)
    services.withdraw(sound.pk, admin_account.pk)
    body = api.get("/v1/catalog").json()
    assert body["revision"] == 3
    ids = {s["id"] for s in body["catalog"]["sons"]}
    assert "vent-doux" not in ids and "jamais-en-ligne" not in ids
    assert "vent-doux" not in body["distant"]["sons"]


@pytest.mark.django_db
def test_revision_increments_on_publish_withdraw_and_edit(admin_account):
    item = publish_item(Kind.SON, "vent-doux")
    assert published_catalog().revision == 1
    services.edit(item.pk, {"nom": "Vent léger", "alias": [], "gratuit": False}, admin_account.pk)
    catalog = published_catalog()
    assert catalog.revision == 2
    assert catalog.catalog.sections["sons"]["vent-doux"]["nom"] == "Vent léger"
    assert not catalog.catalog.is_free("sons", "vent-doux")
    services.withdraw(item.pk, admin_account.pk)
    assert published_catalog().revision == 3
    services.publish(item.pk, admin_account.pk)  # retire -> publie, same files
    catalog = published_catalog()
    assert catalog.revision == 4
    assert catalog.catalog.media_rev("sons", "vent-doux") == 1


@pytest.mark.django_db
def test_a_cached_catalog_costs_one_query():
    publish_item()
    published_catalog()  # builds and caches
    with CaptureQueriesContext(connection) as queries:
        catalog = published_catalog()
    assert len(queries) == 1
    assert "publishing_catalogrevision" in queries[0]["sql"]
    assert catalog.revision == 1


@pytest.mark.django_db
def test_a_published_id_clashing_with_the_base_is_never_served(api):
    # Cannot happen through the dashboard (the form refuses it); if the base catalog ever gains
    # the same id, the base wins.
    publish_item(Kind.SON, "vent", nom="Autre vent")
    body = api.get("/v1/catalog").json()
    vents = [s for s in body["catalog"]["sons"] if s["id"] == "vent"]
    assert len(vents) == 1 and vents[0]["nom"] == "Vent"


@pytest.mark.django_db
def test_rate_limit_is_per_installation(api, settings):
    settings.RATE_CATALOG_PER_HOUR = 1
    assert api.get("/v1/catalog").status_code == 200
    assert api.get("/v1/catalog").status_code == 429
    _, other = make_installation()
    assert client_for(other).get("/v1/catalog").status_code == 200
