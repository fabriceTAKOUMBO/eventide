import base64
from urllib.parse import parse_qs, urlsplit

import pytest
from cryptography.exceptions import InvalidSignature
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import padding, rsa

from apps.content import signing
from conftest import make_purchase


@pytest.fixture
def cloudfront_key(settings):
    key = rsa.generate_private_key(public_exponent=65537, key_size=2048)
    settings.CLOUDFRONT_PRIVATE_KEY = key.private_bytes(
        serialization.Encoding.PEM,
        serialization.PrivateFormat.PKCS8,
        serialization.NoEncryption(),
    ).decode()
    return key.public_key()


def verify(public_key, signed_url: str) -> None:
    parts = urlsplit(signed_url)
    query = parse_qs(parts.query)
    resource = f"{parts.scheme}://{parts.netloc}{parts.path}"
    policy = signing.canned_policy(resource, int(query["Expires"][0]))
    raw = query["Signature"][0].replace("-", "+").replace("_", "=").replace("~", "/")
    public_key.verify(
        base64.b64decode(raw),
        policy.encode(),
        padding.PKCS1v15(),
        hashes.SHA1(),  # noqa: S303
    )
    assert query["Key-Pair-Id"] == ["K2TESTKEYID"]


@pytest.mark.django_db
def test_free_content_is_signed_for_everyone(api, cloudfront_key):
    keys = ["audio/sons/eau-vive.ogg", "images/paysages/cascade-foret.jpg"]
    response = api.post("/v1/content/urls", {"keys": keys}, format="json")
    assert response.status_code == 200
    data = response.json()
    assert set(data["urls"]) == set(keys)
    assert data["expires_at"].endswith("Z")
    for key, url in data["urls"].items():
        assert url.startswith(f"https://cdn.eventide.test/{key}?Expires=")
        verify(cloudfront_key, url)


@pytest.mark.django_db
def test_free_landscape_video_is_signed_for_everyone(api, cloudfront_key):
    keys = ["videos/paysages/cascade-foret.mp4", "videos/paysages/sous-bois.mp4"]
    response = api.post("/v1/content/urls", {"keys": keys}, format="json")
    assert response.status_code == 200
    urls = response.json()["urls"]
    assert set(urls) == set(keys)
    for key, url in urls.items():
        assert url.startswith(f"https://cdn.eventide.test/{key}?Expires=")
        verify(cloudfront_key, url)


@pytest.mark.django_db
def test_tampered_url_does_not_verify(api, cloudfront_key):
    url = api.post("/v1/content/urls", {"keys": ["audio/sons/vent.ogg"]}, format="json").json()[
        "urls"
    ]["audio/sons/vent.ogg"]
    with pytest.raises(InvalidSignature):
        verify(cloudfront_key, url.replace("vent.ogg", "vagues.ogg"))


def test_canned_policy_is_compact():
    assert signing.canned_policy("https://cdn/x.ogg", 10) == (
        '{"Statement":[{"Resource":"https://cdn/x.ogg","Condition":{"DateLessThan":'
        '{"AWS:EpochTime":10}}}]}'
    )


@pytest.mark.django_db
def test_premium_content_requires_premium(api, installation, cloudfront_key):
    body = {"keys": ["audio/sons/eau-vive.ogg", "audio/musiques/harpe.ogg"]}
    response = api.post("/v1/content/urls", body, format="json")
    assert response.status_code == 403
    assert response.json()["error"] == "premium_required"
    make_purchase(installation=installation[0])
    assert api.post("/v1/content/urls", body, format="json").status_code == 200


@pytest.mark.django_db
@pytest.mark.parametrize(
    "keys",
    [
        ["videos/paysages/pluie-ville.mp4"],
        ["images/paysages/aurore-boreale.jpg"],
        ["videos/paysages/cascade-foret.mp4", "videos/paysages/aurore-boreale.mp4"],
    ],
)
def test_premium_landscape_media_requires_premium(api, installation, cloudfront_key, keys):
    response = api.post("/v1/content/urls", {"keys": keys}, format="json")
    assert response.status_code == 403
    assert response.json()["error"] == "premium_required"
    make_purchase(installation=installation[0])
    response = api.post("/v1/content/urls", {"keys": keys}, format="json")
    assert response.status_code == 200
    urls = response.json()["urls"]
    assert set(urls) == set(keys)
    for url in urls.values():
        verify(cloudfront_key, url)


@pytest.mark.django_db
def test_free_landscape_ambiance_is_signed_for_everyone(api, cloudfront_key):
    # Contract § 11: an ambiance is a catalog sound; this one is free (cascade-foret).
    key = "audio/sons/ambiance-cascade-foret.ogg"
    response = api.post("/v1/content/urls", {"keys": [key]}, format="json")
    assert response.status_code == 200
    verify(cloudfront_key, response.json()["urls"][key])


@pytest.mark.django_db
@pytest.mark.parametrize(
    "keys",
    [
        ["audio/sons/ambiance-pluie-ville.ogg"],
        # Variants of the event sound « tonnerre » (Premium): the sound's own rule.
        ["audio/sons/tonnerre-01.ogg"],
        ["audio/sons/tonnerre-10.ogg", "audio/sons/eau-vive.ogg"],
        ["audio/sons/ambiance-cascade-foret.ogg", "audio/sons/tonnerre-03.ogg"],
    ],
)
def test_premium_ambiance_and_event_variants_require_premium(
    api, installation, cloudfront_key, keys
):
    response = api.post("/v1/content/urls", {"keys": keys}, format="json")
    assert response.status_code == 403
    assert response.json()["error"] == "premium_required"
    make_purchase(installation=installation[0])
    response = api.post("/v1/content/urls", {"keys": keys}, format="json")
    assert response.status_code == 200
    urls = response.json()["urls"]
    assert set(urls) == set(keys)
    for key, url in urls.items():
        assert url.startswith(f"https://cdn.eventide.test/{key}?Expires=")
        verify(cloudfront_key, url)


def test_every_variant_of_an_event_sound_is_a_sound_file(catalog):
    for sound in catalog.raw["sons"]:
        for variant in sound.get("variantes", []):
            assert catalog.sound_of_file(variant) == sound["id"]
    assert catalog.sound_of_file("vent") == "vent"
    assert catalog.sound_of_file("tonnerre-99") is None
    assert catalog.sound_of_file("harpe") is None


@pytest.mark.django_db
@pytest.mark.parametrize(
    "keys",
    [
        [],
        ["audio/sons/klaxon.ogg"],
        # Event variants: only under audio/sons, only the listed ones.
        ["audio/sons/tonnerre-99.ogg"],
        ["audio/sons/tonnerre-1.ogg"],
        ["audio/musiques/tonnerre-01.ogg"],
        ["images/paysages/tonnerre-01.jpg"],
        ["videos/paysages/tonnerre-01.mp4"],
        ["audio/sons/tonnerre-01.mp4"],
        ["audio/sons/ambiance-pluie-ville.mp4"],
        ["videos/paysages/ambiance-pluie-ville.mp4"],
        ["audio/sons/harpe.ogg"],
        ["audio/sons/eau-vive.mp3"],
        ["images/paysages/eau-vive.jpg"],
        ["../etc/passwd"],
        ["audio/sons/vent.ogg\n"],
        # Landscape videos: unknown or non-landscape id, wrong prefix or extension, traversal.
        ["videos/paysages/klaxon.mp4"],
        ["videos/paysages/eau-vive.mp4"],
        ["videos/sons/vent.mp4"],
        ["audio/sons/vent.mp4"],
        ["images/paysages/cascade-foret.mp4"],
        ["videos/paysages/cascade-foret.jpg"],
        ["videos/paysages/cascade-foret.ogg"],
        ["videos/paysages/cascade-foret.webm"],
        ["videos/paysages/cascade-foret.MP4"],
        ["videos/paysages/cascade-foret.mp4.mp4"],
        ["videos/paysages/cascade-foret"],
        ["Videos/paysages/cascade-foret.mp4"],
        ["/videos/paysages/cascade-foret.mp4"],
        ["videos//paysages/cascade-foret.mp4"],
        ["videos/paysages/../paysages/cascade-foret.mp4"],
        ["videos/paysages/../../audio/sons/vent.ogg"],
        ["videos/paysages/%2e%2e/cascade-foret.mp4"],
        ["videos/paysages/cascade-foret.mp4\n"],
        ["videos/paysages/cascade-foret.mp4 "],
        ["videos/paysages/cascade-foret.mp4?x=1"],
        ["videos/paysages/cascade-foret.mp4", "videos/paysages/cascade-foret.mp4"],
        ["audio/sons/eau-vive.ogg", "audio/sons/eau-vive.ogg"],
        [3],
        ["audio/sons/vent.ogg"] * 31,
    ],
)
def test_invalid_keys_are_400(api, keys, cloudfront_key):
    assert api.post("/v1/content/urls", {"keys": keys}, format="json").status_code == 400


@pytest.mark.django_db
def test_not_configured_is_503(api, settings):
    settings.CLOUDFRONT_PRIVATE_KEY = ""
    response = api.post("/v1/content/urls", {"keys": ["audio/sons/vent.ogg"]}, format="json")
    assert response.status_code == 503
    assert response.json()["error"] == "content_unavailable"


def test_non_rsa_key_is_refused(settings):
    from cryptography.hazmat.primitives.asymmetric import ec

    key = ec.generate_private_key(ec.SECP256R1())
    pem = key.private_bytes(
        serialization.Encoding.PEM, serialization.PrivateFormat.PKCS8, serialization.NoEncryption()
    ).decode()
    settings.CLOUDFRONT_PRIVATE_KEY = pem
    with pytest.raises(signing.SigningNotConfigured):
        signing.sign("https://cdn.eventide.test/a.ogg", 10)
