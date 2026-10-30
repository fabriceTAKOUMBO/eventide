"""The API validates against the published catalog (contract § 13): content keys carry the
current media revision; shares accept published ids and refuse withdrawn ones."""

import pytest
from cryptography.hazmat.primitives import serialization
from cryptography.hazmat.primitives.asymmetric import rsa

from apps.publishing import services
from apps.publishing.models import PublishedItem
from apps.shares.models import Share
from conftest import make_installation, make_purchase

from .conftest import publish_item

Kind = PublishedItem.Kind


@pytest.fixture
def signing_key(settings):
    key = rsa.generate_private_key(public_exponent=65537, key_size=2048)
    settings.CLOUDFRONT_PRIVATE_KEY = key.private_bytes(
        serialization.Encoding.PEM,
        serialization.PrivateFormat.PKCS8,
        serialization.NoEncryption(),
    ).decode()


def urls(api, *keys):
    return api.post("/v1/content/urls", {"keys": list(keys)}, format="json")


@pytest.fixture
def published(db):
    return {
        "son": publish_item(Kind.SON, "vent-doux", nom="Vent doux", media_rev=2),
        "musique": publish_item(Kind.MUSIQUE, "piano-nuit", nom="Piano de nuit", gratuit=False),
        "paysage": publish_item(
            Kind.PAYSAGE,
            "lac-brume",
            nom="Lac dans la brume",
            theme="nature",
            has_ambiance=True,
            media_rev=4,
        ),
    }


@pytest.mark.django_db
def test_current_revision_keys_of_published_elements_are_signed(api, signing_key, published):
    keys = [
        "audio/sons/vent-doux.v2.ogg",
        "videos/paysages/lac-brume.v4.mp4",
        "images/paysages/lac-brume.v4.jpg",
        "audio/sons/ambiance-lac-brume.v4.ogg",
        # Base items keep their unversioned keys.
        "audio/sons/eau-vive.ogg",
        "images/paysages/cascade-foret.jpg",
    ]
    response = urls(api, *keys)
    assert response.status_code == 200, response.json()
    signed = response.json()["urls"]
    assert set(signed) == set(keys)
    assert signed["audio/sons/vent-doux.v2.ogg"].startswith(
        "https://cdn.eventide.test/audio/sons/vent-doux.v2.ogg?Expires="
    )


@pytest.mark.django_db
@pytest.mark.parametrize(
    "key",
    [
        "audio/sons/vent-doux.ogg",  # a published element always carries its revision
        "audio/sons/vent-doux.v1.ogg",  # an older revision
        "audio/sons/vent-doux.v3.ogg",  # a future one
        "audio/sons/vent-doux.v0.ogg",
        "videos/paysages/lac-brume.mp4",
        "audio/sons/ambiance-lac-brume.v3.ogg",
        "audio/sons/eau-vive.v1.ogg",  # a base item has none
        "audio/sons/tonnerre-coup-01.v1.ogg",
        "audio/musiques/vent-doux.v2.ogg",  # wrong section
        "audio/sons/vent-doux.v2.mp4",
        "audio/sons/vent-doux.v02.ogg",
    ],
)
def test_other_revisions_and_shapes_are_refused(api, signing_key, published, key):
    response = urls(api, key)
    assert response.status_code == 400
    assert response.json()["error"] == "invalid_request"


@pytest.mark.django_db
def test_withdrawn_elements_are_unknown(api, signing_key, published, admin_account):
    assert urls(api, "audio/sons/vent-doux.v2.ogg").status_code == 200
    services.withdraw(published["son"].pk, admin_account.pk)
    assert urls(api, "audio/sons/vent-doux.v2.ogg").status_code == 400


@pytest.mark.django_db
def test_published_premium_element_requires_premium(api, installation, signing_key, published):
    response = urls(api, "audio/musiques/piano-nuit.v1.ogg")
    assert response.status_code == 403
    assert response.json()["error"] == "premium_required"
    make_purchase(installation=installation[0])
    assert urls(api, "audio/musiques/piano-nuit.v1.ogg").status_code == 200


SCENE = {
    "version": 1,
    "paysage": "lac-brume",
    "moment": "nuit",
    "sons": [{"id": "ambiance-lac-brume", "niveau": 60}, {"id": "vent-doux", "niveau": 30}],
    "musique": [{"id": "piano-nuit", "niveau": 20}],
    "decor": [],
}


@pytest.mark.django_db
def test_shares_accept_published_elements(api, published):
    response = api.post("/v1/shares", {"scene": SCENE}, format="json")
    assert response.status_code == 201
    code = response.json()["code"]
    assert Share.objects.get(code=code).scene == SCENE


@pytest.mark.django_db
@pytest.mark.parametrize("withdrawn", ["paysage", "son", "musique"])
def test_shares_refuse_withdrawn_elements(api, published, admin_account, withdrawn):
    services.withdraw(published[withdrawn].pk, admin_account.pk)
    response = api.post("/v1/shares", {"scene": SCENE}, format="json")
    assert response.status_code == 400


@pytest.mark.django_db
def test_share_page_of_a_withdrawn_landscape_opens_the_default(client, published, admin_account):
    inst, _ = make_installation()
    Share.objects.create(code="Lac1Brum", scene=SCENE, installation=inst)
    page = client.get("/m/Lac1Brum").content.decode()
    assert "Lac dans la brume" in page and "Vent doux" in page
    services.withdraw(published["paysage"].pk, admin_account.pk)
    services.withdraw(published["son"].pk, admin_account.pk)
    page = client.get("/m/Lac1Brum").content.decode()
    assert "Cascade en forêt" in page and "Lac dans la brume" not in page
    assert "Vent doux" not in page and "Piano de nuit" in page


@pytest.mark.django_db
def test_standalone_share_page_names_published_elements(client, published):
    html = client.get("/s").content.decode()
    assert '"piano-nuit"' in html and "vent-doux" in html
