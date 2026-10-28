import copy

import pytest

from apps.shares.models import Share
from apps.shares.views import ALPHABET
from conftest import client_for, make_installation

SCENE = {
    "version": 1,
    "paysage": "cascade-foret",
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
        "paysage": "cascade-foret",
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
        broken(moment="midi"),
        broken(sons="eau-vive"),
        broken(sons=[{"id": "klaxon", "niveau": 10}]),
        broken(sons=[{"id": "vent", "niveau": 101}]),
        broken(sons=[{"id": "vent", "niveau": 10.5}]),
        broken(sons=[{"id": "vent", "niveau": 10}, {"id": "vent", "niveau": 20}]),
        broken(musique=[{"id": "vent", "niveau": 10}]),
        broken(decor=["brume"]),
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
