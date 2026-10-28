import copy

import pytest

from apps.voice import prompt
from apps.voice.validator import validate_ops


def test_unknown_plan_is_a_programming_error():
    with pytest.raises(ValueError, match="unknown plan"):
        validate_ops([], "gold")


def test_input_is_not_modified():
    ops = [{"op": "ajouter", "cible": "son", "id": "vent", "extra": 1}]
    before = copy.deepcopy(ops)
    validate_ops(ops, "free")
    assert ops == before


def test_every_output_op_is_valid_again():
    """Idempotence: validating an output gives it back unchanged."""
    ops = [
        {"op": "ajouter", "cible": "son", "id": "vent"},
        {"op": "creer", "cible": "programmation", "valeur": {"heure": "22:00", "jours": [3, 1]}},
        {"op": "definir", "cible": "paysage", "valeur": "aurore-boreale"},
    ]
    once = validate_ops(ops, "free")
    assert validate_ops(once, "free") == once


@pytest.mark.parametrize("plan", ["monthly", "annual", "lifetime"])
def test_premium_plans_keep_premium_items(plan):
    ops = [{"op": "ajouter", "cible": "decor", "id": "etoiles", "niveau": 60}]
    assert validate_ops(ops, plan) == ops


def test_wire_format_is_mapped_to_contract_operations():
    wire = [
        {"op": "definir", "cible": "paysage", "valeur_texte": "lune-lac"},
        {"op": "definir", "cible": "minuteur", "minuteur": {"mode": "duree", "minutes": 90}},
        {"op": "definir", "cible": "sommeil.suivi", "valeur_booleen": True},
        {"op": "definir", "cible": "reglage", "cle": "taille_texte", "valeur_nombre": 2},
        {
            "op": "creer",
            "cible": "programmation",
            "programmation": {"heure": "22:00", "jours": [1]},
        },
        {
            "op": "modifier",
            "cible": "programmation",
            "selecteur": {"heure": "22:00"},
            "programmation": {"heure": "22:30"},
        },
        {"op": "regler", "cible": "son", "id": "vent", "niveau": 30},
        "not-an-object",
    ]
    ops = prompt.to_contract_ops(wire)
    assert ops[0] == {"op": "definir", "cible": "paysage", "valeur": "lune-lac"}
    assert ops[1]["valeur"] == {"mode": "duree", "minutes": 90}
    assert ops[2]["valeur"] is True
    assert ops[3]["valeur"] == 2
    assert ops[4]["valeur"] == {"heure": "22:00", "jours": [1]}
    assert ops[5]["selecteur"] == {"heure": "22:00"} and ops[5]["valeur"] == {"heure": "22:30"}
    assert ops[6] == {"op": "regler", "cible": "son", "id": "vent", "niveau": 30}
    assert ops[7] == "not-an-object"
    assert prompt.to_contract_ops({"actions": []}) == []
    assert validate_ops(ops, "monthly")[:2] == [ops[0], ops[1]]


def test_instruction_contains_the_catalog_and_no_premium_flags():
    text = prompt.system_instruction()
    assert "cascade-foret" in text and "bols-tibetains" in text
    assert "gratuit" not in text.lower().split("catalogue")[-1]


def test_state_summary_keeps_ids_and_levels_only():
    state = {
        "scene": {
            "paysage": "cascade-foret",
            "sons": [{"id": "vent", "niveau": 30, "x": 1}],
            "musique": "bad",
            "decor": [5],
        },
        "programmations": [{"id": "a", "heure": "22:00", "secret": "no"}, 3],
        "lecture": "en_cours",
    }
    summary = prompt.state_summary(state)
    assert summary["sons"] == [{"id": "vent", "niveau": 30}]
    assert summary["musique"] == [] and summary["decor"] == []
    assert "secret" not in str(summary)
    assert prompt.state_summary({"scene": "bad"})["paysage"] is None
