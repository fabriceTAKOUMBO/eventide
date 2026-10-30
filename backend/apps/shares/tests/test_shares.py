import copy

import pytest

from apps.shares.models import Share
from apps.shares.views import ALPHABET
from conftest import client_for, make_installation

SCENE = {
    "version": 1,
    # A 3D scene (contract § 12): its decor applies.
    "paysage": "foret-lucioles",
    "moment": "jour",
    "sons": [{"id": "eau-vive", "niveau": 60}, {"id": "oiseaux", "niveau": 0}],
    "musique": [{"id": "harpe", "niveau": 25}],
    "decor": [{"id": "brume", "niveau": 30}],
    "minuteur": {"mode": "duree", "minutes": 60},
    "sommeil": {"suivi": True},
    "prenom": "Fabrice",
}


@pytest.mark.django_db
def test_create_and_read_a_share(api):
    response = api.post("/v1/shares", {"scene": SCENE}, format="json")
    assert response.status_code == 201
    data = response.json()
    code = data["code"]
    assert len(code) == 8 and all(c in ALPHABET for c in code)
    assert data["url"] == f"https://eventide.test/m/{code}"
    scene = api.get(f"/v1/shares/{code}").json()["scene"]
    assert scene == {
        "version": 1,
        "paysage": "foret-lucioles",
        "moment": "jour",
        "sons": [{"id": "eau-vive", "niveau": 60}],
        "musique": [{"id": "harpe", "niveau": 25}],
        "decor": [{"id": "brume", "niveau": 30}],
    }  # no minuteur, no sommeil, no unknown field (no personal data)
    # Any installation can read it.
    _, other = make_installation()
    assert client_for(other).get(f"/v1/shares/{code}").status_code == 200


@pytest.mark.django_db
@pytest.mark.parametrize(
    "sourdine",
    [{"sons": True, "musique": True}, {"musique": True}, "oui", None, [1]],
)
def test_the_mute_is_accepted_but_never_shared(api, sourdine):
    """``sourdine`` (contract § 1) is accepted whatever its shape and dropped: the recipient
    hears the mix."""
    response = api.post("/v1/shares", {"scene": {**SCENE, "sourdine": sourdine}}, format="json")
    assert response.status_code == 201
    scene = api.get(f"/v1/shares/{response.json()['code']}").json()["scene"]
    assert "sourdine" not in scene
    assert scene["musique"] == [{"id": "harpe", "niveau": 25}]


@pytest.mark.django_db
@pytest.mark.parametrize(
    ("paysage", "decor", "kept"),
    [
        # A filmed landscape: its decor is not editable, every element is dropped.
        ("cascade-foret", [{"id": "brume", "niveau": 30}], []),
        ("pluie-ville", [{"id": "neige", "niveau": 40}, {"id": "eclairs", "niveau": 50}], []),
        # A 3D scene keeps the ids of its own ``decors`` only; ids removed from the catalog
        # (``eclairs``, ``pluie-ecran``) are dropped like any other that does not apply.
        (
            "foret-lucioles",
            [
                {"id": "lucioles", "niveau": 60},
                {"id": "neige", "niveau": 30},
                {"id": "eclairs", "niveau": 50},
                {"id": "pluie-ecran", "niveau": 20},
                {"id": "brume", "niveau": 0},
            ],
            [{"id": "lucioles", "niveau": 60}],
        ),
        (
            "aurore",
            [{"id": "neige", "niveau": 30}, {"id": "petales", "niveau": 40}],
            [{"id": "neige", "niveau": 30}],
        ),
    ],
)
def test_decor_that_does_not_apply_is_dropped_without_error(api, paysage, decor, kept):
    """Contract § 12: decor only on a 3D scene, only for its ``decors``."""
    response = api.post(
        "/v1/shares", {"scene": {**SCENE, "paysage": paysage, "decor": decor}}, format="json"
    )
    assert response.status_code == 201
    scene = api.get(f"/v1/shares/{response.json()['code']}").json()["scene"]
    assert scene["paysage"] == paysage
    assert scene["decor"] == kept
    assert scene["sons"] == [{"id": "eau-vive", "niveau": 60}]


@pytest.mark.django_db
@pytest.mark.parametrize("code", ["NOPE1234", "short", "bad-code", "x" * 9])
def test_unknown_share_is_404(api, code):
    response = api.get(f"/v1/shares/{code}")
    assert response.status_code == 404
    assert response.json()["error"] == "not_found"


def broken(**changes):
    scene = copy.deepcopy(SCENE)
    scene.update(changes)
    return scene


@pytest.mark.django_db
@pytest.mark.parametrize(
    "scene",
    [
        None,
        [],
        broken(version=2),
        broken(version=True),
        broken(paysage="nulle-part"),
        # Retired 2D landscape (contract § 12): never stored again.
        broken(paysage="sous-bois"),
        broken(moment="midi"),
        broken(sons="eau-vive"),
        broken(sons=[{"id": "klaxon", "niveau": 10}]),
        broken(sons=[{"id": "vent", "niveau": 101}]),
        broken(sons=[{"id": "vent", "niveau": 10.5}]),
        broken(sons=[{"id": "vent", "niveau": 10}, {"id": "vent", "niveau": 20}]),
        broken(musique=[{"id": "vent", "niveau": 10}]),
        broken(decor=["brume"]),
        # A decor element that would be dropped must still be well formed.
        broken(decor=[{"niveau": 30}]),
        broken(decor=[{"id": "", "niveau": 30}]),
        broken(decor=[{"id": "neige", "niveau": 101}]),
        broken(decor=[{"id": "eclairs", "niveau": True}]),
        broken(decor=[{"id": "brume", "niveau": 30}, {"id": "brume", "niveau": 10}]),
        broken(paysage="cascade-foret", decor=[{"id": "brume", "niveau": "30"}]),
        broken(
            sons=[
                {"id": i, "niveau": 10}
                for i in ("eau-vive", "oiseaux", "vent", "tonnerre", "pluie-douce")
            ],
            musique=[{"id": "harpe", "niveau": 1}, {"id": "flute", "niveau": 1}],
        ),
    ],
)
def test_invalid_scenes_are_400(api, scene):
    response = api.post("/v1/shares", {"scene": scene}, format="json")
    assert response.status_code == 400
    assert response.json()["error"] == "invalid_request"
    assert not Share.objects.exists()


@pytest.mark.django_db
def test_twenty_shares_per_day(api, settings):
    settings.RATE_SHARES_PER_DAY = 2
    for _ in range(2):
        assert api.post("/v1/shares", {"scene": SCENE}, format="json").status_code == 201
    response = api.post("/v1/shares", {"scene": SCENE}, format="json")
    assert response.status_code == 429


@pytest.mark.django_db
def test_code_collision_is_retried(api, monkeypatch):
    first = api.post("/v1/shares", {"scene": SCENE}, format="json").json()["code"]
    codes = iter([first, "Abcdefgh"])
    monkeypatch.setattr("apps.shares.views.new_code", lambda: next(codes))
    assert api.post("/v1/shares", {"scene": SCENE}, format="json").json()["code"] == "Abcdefgh"
