import base64
import json

import pytest

from apps.shares.models import Share
from conftest import make_installation

SCENE = {
    "version": 1,
    "paysage": "aurore-boreale",
    "moment": "nuit",
    "sons": [{"id": "vent", "niveau": 30}],
    "musique": [{"id": "nappes-apaisantes", "niveau": 30}],
    "decor": [{"id": "etoiles", "niveau": 40}],
}


@pytest.mark.django_db
def test_share_landing_page(client):
    inst, _ = make_installation()
    Share.objects.create(code="Ab12Cd34", scene=SCENE, installation=inst)
    response = client.get("/m/Ab12Cd34")
    assert response.status_code == 200
    html = response.content.decode()
    assert "Aurore boréale" in html and "Premium" in html
    assert "Nappes apaisantes" in html and "40 %" in html
    assert "https://play.google.com/store/apps/details?id=app.eventide.test" in html
    assert "intent://eventide.test/m/Ab12Cd34#Intent;scheme=https;package=app.eventide.test" in html
    assert "script-src 'self'" in response["Content-Security-Policy"]
    assert "<script>" not in html


@pytest.mark.django_db
@pytest.mark.parametrize("code", ["Zz99Zz99", "bad"])
def test_unknown_share_page_is_404(client, code):
    response = client.get(f"/m/{code}")
    assert response.status_code == 404
    assert "n'existe plus" in response.content.decode()


def test_standalone_share_page_embeds_the_catalog_safely(client):
    response = client.get("/s")
    assert response.status_code == 200
    html = response.content.decode()
    assert '<script id="catalogue" type="application/json">' in html
    assert "web/partage.js" in html
    catalogue = json.loads(html.split('type="application/json">')[1].split("</script>")[0])
    assert catalogue["paysages"]["cascade-foret"] == {"nom": "Cascade en forêt", "gratuit": True}
    # The scene travels in the fragment, never seen by the server:
    fragment = base64.urlsafe_b64encode(json.dumps(SCENE).encode()).decode().rstrip("=")
    assert client.get(f"/s#{fragment}").status_code == 200


def test_static_script_is_served(client):
    response = client.get("/static/web/partage.js")
    assert response.status_code == 200


def test_assetlinks(client, settings):
    response = client.get("/.well-known/assetlinks.json")
    assert response.status_code == 200
    assert response.json() == [
        {
            "relation": ["delegate_permission/common.handle_all_urls"],
            "target": {
                "namespace": "android_app",
                "package_name": "app.eventide.test",
                "sha256_cert_fingerprints": ["AA:BB:CC"],
            },
        }
    ]
    settings.ANDROID_CERT_FINGERPRINTS = []
    assert client.get("/.well-known/assetlinks.json").status_code == 404


def test_privacy_policy_mentions_us_hosting_and_voice(client, settings):
    settings.LEGAL_CONTACT_EMAIL = "confidentialite@exemple.test"
    response = client.get("/confidentialite")
    assert response.status_code == 200
    html = response.content.decode()
    assert "États-Unis (Virginie du Nord)" in html
    assert "Jamais le son de votre voix, jamais le texte de votre phrase" in html
    assert "confidentialite@exemple.test" in html
    assert "Gemini" in html


def test_pages_refuse_post(client):
    assert client.post("/confidentialite").status_code == 405
