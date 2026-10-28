"""POST /v1/voice end to end, with the Gemini API mocked (``responses``)."""

import json
import logging
from decimal import Decimal

import pytest
import responses

from apps.accounts.models import Account
from apps.installations.models import Installation
from apps.voice.models import VoiceGlobalDay, VoiceMonthlyUsage, VoiceRequest
from conftest import client_for, make_installation, make_purchase

GEMINI_URL = "https://gemini.test/v1beta/models/gemini-2.5-flash-lite:generateContent"
PHRASE = "mets la pluie à septante pour cent s'il te plaît"
NORMALISED = "mets la pluie à 70 pour cent s'il te plaît"


def body(**overrides):
    data = {
        "phrase": PHRASE,
        "phrase_normalisee": NORMALISED,
        "etat": {
            "scene": {
                "version": 1,
                "paysage": "cascade-foret",
                "moment": "jour",
                "sons": [{"id": "pluie-douce", "niveau": 40}],
                "musique": [],
                "decor": [],
            },
            "programmations": [],
            "lecture": "en_cours",
            "reglages": {"taille_texte": 0},
        },
        "actions_locales": None,
    }
    data.update(overrides)
    return data


def gemini_answer(actions, prompt_tokens=1200, output_tokens=150, thoughts=0):
    usage = {"promptTokenCount": prompt_tokens, "candidatesTokenCount": output_tokens}
    if thoughts:
        usage["thoughtsTokenCount"] = thoughts
    return {
        "candidates": [
            {"content": {"parts": [{"text": json.dumps({"actions": actions})}], "role": "model"}}
        ],
        "usageMetadata": usage,
    }


@pytest.fixture
def gemini():
    with responses.RequestsMock(assert_all_requests_are_fired=False) as mock:
        yield mock


def post(client, data=None):
    return client.post("/v1/voice", data or body(), format="json")


@pytest.mark.django_db
def test_model_answer_is_validated_counted_and_costed(api, installation, gemini):
    inst, _ = installation
    gemini.post(
        GEMINI_URL,
        json=gemini_answer([{"op": "regler", "cible": "son", "id": "pluie-douce", "niveau": 70}]),
    )
    response = post(api)
    assert response.status_code == 200
    data = response.json()
    assert data["source"] == "model"
    assert data["actions"] == [{"op": "regler", "cible": "son", "id": "pluie-douce", "niveau": 70}]
    assert data["voice"] == {
        "mode": "trial",
        "trial_remaining": 2,
        "credits_remaining": 0,
        "monthly_cap_reached": False,
    }
    request = VoiceRequest.objects.get()
    assert (request.status, request.charge, request.cost_micro_eur) == ("settled", "trial", 168)
    assert VoiceGlobalDay.objects.get().spent_micro_eur == 168
    # What was sent to Gemini.
    sent = gemini.calls[0].request
    assert sent.headers["x-goog-api-key"] == "test-only-gemini-key"
    assert "key=" not in sent.url
    payload = json.loads(sent.body)
    config = payload["generationConfig"]
    assert config["responseMimeType"] == "application/json"
    assert config["responseSchema"]["properties"]["actions"]["type"] == "ARRAY"
    assert config["thinkingConfig"] == {"thinkingBudget": 0}
    assert NORMALISED in payload["contents"][0]["parts"][0]["text"]
    assert PHRASE not in payload["contents"][0]["parts"][0]["text"]


@pytest.mark.django_db
def test_phrase_is_never_logged(api, gemini, caplog, capsys, monkeypatch):
    for name in ("apps", "django"):  # our loggers do not propagate to the root by default
        monkeypatch.setattr(logging.getLogger(name), "propagate", True)
    gemini.post(GEMINI_URL, json=gemini_answer([{"op": "lecture", "valeur": "pause"}]))
    with caplog.at_level(logging.DEBUG, logger="apps"), caplog.at_level(logging.DEBUG):
        post(api)
    events = [getattr(record, "event", None) for record in caplog.records]
    assert "voice_answered" in events
    logged = " ".join(str(r.__dict__) for r in caplog.records) + capsys.readouterr().out
    assert "septante" not in logged and "70 pour cent" not in logged
    assert not VoiceRequest.objects.filter(model__icontains="pluie").exists()


@pytest.mark.django_db
def test_thinking_tokens_are_billed_as_output(api, gemini):
    gemini.post(GEMINI_URL, json=gemini_answer([{"op": "partager"}], 1000, 100, thoughts=1000))
    post(api)
    request = VoiceRequest.objects.get()
    assert (request.input_tokens, request.output_tokens) == (1000, 1100)


@pytest.mark.django_db
def test_trial_exhausted_is_402(gemini):
    _, token = make_installation(trial_used=3)
    response = post(client_for(token))
    assert response.status_code == 402
    assert response.json()["error"] == "voice_quota_exhausted"
    assert not gemini.calls


@pytest.mark.django_db
def test_credits_after_the_trial(gemini):
    inst, token = make_installation(trial_used=3, credits=2)
    gemini.post(GEMINI_URL, json=gemini_answer([{"op": "partager"}]))
    data = post(client_for(token)).json()
    assert data["voice"]["credits_remaining"] == 1


@pytest.mark.django_db
@pytest.mark.parametrize("status", [429, 500, 503])
def test_model_failure_releases_the_reservation(api, installation, gemini, status):
    gemini.post(GEMINI_URL, status=status, json={})
    response = post(api)
    assert response.status_code == 503
    assert response.json()["error"] == "model_unavailable"
    inst, _ = installation
    inst.refresh_from_db()
    assert inst.trial_used == 0
    assert VoiceRequest.objects.get().status == "released"
    assert VoiceGlobalDay.objects.get().reserved_micro_eur == 0


@pytest.mark.django_db
def test_network_error_releases_the_reservation(api, installation, gemini):
    import requests

    gemini.post(GEMINI_URL, body=requests.ConnectionError("down"))
    assert post(api).status_code == 503
    inst, _ = installation
    inst.refresh_from_db()
    assert inst.trial_used == 0


@pytest.mark.django_db
def test_unexpected_error_also_releases(api, installation, monkeypatch):
    def boom(**kwargs):
        raise RuntimeError("bug")

    monkeypatch.setattr("apps.voice.routers.gemini.GeminiRouter.route", lambda self, **kw: boom())
    with pytest.raises(RuntimeError):
        post(api)
    assert VoiceRequest.objects.get().status == "released"


@pytest.mark.django_db
def test_unparsable_model_output_asks_to_rephrase_but_counts_the_cost(api, gemini):
    answer = gemini_answer([])
    answer["candidates"][0]["content"]["parts"][0]["text"] = "Bien sûr ! Je mets la pluie."
    gemini.post(GEMINI_URL, json=answer)
    data = post(api).json()
    assert data["actions"] == [{"op": "reformuler", "raison": "incompris"}]
    assert VoiceRequest.objects.get().cost_micro_eur == 168


@pytest.mark.django_db
def test_blocked_answer_without_candidates(api, gemini):
    gemini.post(GEMINI_URL, json={"promptFeedback": {"blockReason": "OTHER"}, "usageMetadata": {}})
    data = post(api).json()
    assert data["actions"] == [{"op": "reformuler", "raison": "incompris"}]


@pytest.mark.django_db
def test_free_user_asking_premium_item_gets_open_premium(api, gemini):
    gemini.post(GEMINI_URL, json=gemini_answer([{"op": "ajouter", "cible": "son", "id": "vagues"}]))
    assert post(api).json()["actions"] == [{"op": "ouvrir", "cible": "premium"}]


@pytest.mark.django_db
def test_subscriber_cost_counts_against_the_monthly_cap(gemini, settings):
    inst, token = make_installation()
    make_purchase(installation=inst, base_plan_id="annual")
    gemini.post(
        GEMINI_URL, json=gemini_answer([{"op": "definir", "cible": "moment", "valeur": "nuit"}])
    )
    data = post(client_for(token)).json()
    assert data["voice"]["mode"] == "included"
    usage = VoiceMonthlyUsage.objects.get()
    assert (usage.spent_micro_eur, usage.reserved_micro_eur, usage.requests) == (168, 0, 1)
    # Cap reached: 402 voice_monthly_cap, the model is not called.
    VoiceMonthlyUsage.objects.update(spent_micro_eur=2_000_000)
    calls = len(gemini.calls)
    response = post(client_for(token))
    assert response.status_code == 402
    assert response.json()["error"] == "voice_monthly_cap"
    assert len(gemini.calls) == calls
    assert client_for(token).get("/v1/entitlements").json()["voice"]["monthly_cap_reached"] is True


@pytest.mark.django_db
def test_linked_subscriber_cap_is_per_account(gemini):
    account = Account.objects.create(google_sub="s")
    make_purchase(account=account)
    _, token = make_installation(account=account)
    gemini.post(GEMINI_URL, json=gemini_answer([{"op": "partager"}]))
    post(client_for(token))
    assert VoiceMonthlyUsage.objects.get().account_id == account.pk


@pytest.mark.django_db
def test_local_actions_are_counted_and_validated_without_model(api, installation, gemini):
    data = post(
        api, body(actions_locales=[{"op": "lecture", "valeur": "pause"}, {"op": "x"}])
    ).json()
    assert data == {
        "actions": [{"op": "lecture", "valeur": "pause"}],
        "source": "local",
        "voice": {
            "mode": "trial",
            "trial_remaining": 2,
            "credits_remaining": 0,
            "monthly_cap_reached": False,
        },
    }
    assert not gemini.calls
    assert VoiceRequest.objects.get().status == "settled"


@pytest.mark.django_db
def test_local_actions_when_exhausted_are_402(gemini):
    _, token = make_installation(trial_used=3)
    response = post(client_for(token), body(actions_locales=[{"op": "partager"}]))
    assert response.status_code == 402


@pytest.mark.django_db
def test_local_actions_of_a_subscriber_are_not_counted(gemini):
    inst, token = make_installation()
    make_purchase(installation=inst)
    data = post(client_for(token), body(actions_locales=[{"op": "partager"}])).json()
    assert data["source"] == "local"
    assert VoiceRequest.objects.get().charge == "none"
    assert not VoiceMonthlyUsage.objects.exists()


@pytest.mark.django_db
@pytest.mark.parametrize(
    "overrides",
    [
        {"phrase": ""},
        {"phrase": "x" * 501},
        {"phrase": 12},
        {"phrase_normalisee": "   "},
        {"etat": []},
        {"etat": {"blob": "x" * 40_000}},
        {"actions_locales": {"op": "pause"}},
        {"actions_locales": [{"op": "partager"}] * 51},
    ],
)
def test_invalid_voice_requests_are_422(api, overrides):
    response = post(api, body(**overrides))
    assert response.status_code == 422
    assert response.json()["error"] == "invalid_request"


@pytest.mark.django_db
def test_non_object_voice_body_is_422(api):
    assert api.post("/v1/voice", [1], format="json").status_code == 422


@pytest.mark.django_db
def test_rate_limit_per_minute(api, settings, gemini):
    settings.VOICE_RATE_PER_MINUTE = 1
    gemini.post(GEMINI_URL, json=gemini_answer([{"op": "partager"}]))
    assert post(api).status_code == 200
    response = post(api)
    assert response.status_code == 429
    assert response.json()["error"] == "rate_limited"


@pytest.mark.django_db
def test_global_daily_cap_answers_503(api, installation, settings, gemini):
    settings.VOICE_GLOBAL_DAILY_CAP_EUR = Decimal("0.001")
    response = post(api)
    assert response.status_code == 503
    inst, _ = installation
    inst.refresh_from_db()
    assert inst.trial_used == 0


@pytest.mark.django_db
def test_rules_only_router(api, settings, gemini):
    settings.VOICE_ROUTER = "rules-only"
    data = post(api, body(phrase="Pause !", phrase_normalisee="Pause !")).json()
    assert data["actions"] == [{"op": "lecture", "valeur": "pause"}]
    assert data["source"] == "model"
    assert post(api).json()["actions"] == [{"op": "reformuler", "raison": "incompris"}]
    assert not gemini.calls
    assert VoiceRequest.objects.filter(cost_micro_eur=0).count() == 2


@pytest.mark.django_db
def test_jev_router_is_not_available_yet(api, installation, settings):
    settings.VOICE_ROUTER = "jev"
    assert post(api).status_code == 503
    inst, _ = installation
    inst.refresh_from_db()
    assert inst.trial_used == 0


@pytest.mark.django_db
def test_voice_disabled(api, settings):
    settings.VOICE_ENABLED = False
    assert post(api).status_code == 503
    local = post(api, body(actions_locales=[{"op": "partager"}]))
    assert local.status_code == 200 and local.json()["voice"]["mode"] == "none"


@pytest.mark.django_db
def test_requires_authentication(client):
    assert client.post("/v1/voice", {}, content_type="application/json").status_code == 401
    assert Installation.objects.count() == 0
