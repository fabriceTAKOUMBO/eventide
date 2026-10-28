"""Instruction, response schema and output mapping of the model (Gemini Flash-Lite family).

The model answers in a WIRE format whose fields each have a single type (``responseSchema`` is
an OpenAPI subset without unions): ``valeur_texte``, ``valeur_booleen``, ``valeur_nombre``,
``minuteur``, ``programmation``. ``to_contract_ops`` turns it into the operations of contract § 3,
which the validator then checks like any other list.
"""

from __future__ import annotations

import json
from typing import Any

from apps.core.catalog import get_catalog

PROMPT_VERSION = "v2"

MODEL_OPS = [
    "definir",
    "changer",
    "ajouter",
    "retirer",
    "regler",
    "ajuster",
    "couper",
    "remettre",
    "lecture",
    "creer",
    "modifier",
    "activer",
    "desactiver",
    "supprimer",
    "commencer_nuit",
    "partager",
    "ouvrir",
    "reformuler",
    "refuser",
]
MODEL_TARGETS = [
    "paysage",
    "moment",
    "son",
    "musique",
    "decor",
    "minuteur",
    "programmation",
    "sommeil.suivi",
    "reglage",
    "premium",
]

RESPONSE_SCHEMA: dict[str, Any] = {
    "type": "OBJECT",
    "properties": {
        "actions": {
            "type": "ARRAY",
            "items": {
                "type": "OBJECT",
                "properties": {
                    "op": {"type": "STRING", "enum": MODEL_OPS},
                    "cible": {"type": "STRING", "enum": MODEL_TARGETS},
                    "id": {"type": "STRING"},
                    "niveau": {"type": "INTEGER"},
                    "delta": {"type": "INTEGER"},
                    "valeur_texte": {"type": "STRING"},
                    "valeur_booleen": {"type": "BOOLEAN"},
                    "valeur_nombre": {"type": "INTEGER"},
                    "minuteur": {
                        "type": "OBJECT",
                        "properties": {
                            "mode": {"type": "STRING", "enum": ["duree", "nuit", "aucun"]},
                            "minutes": {"type": "INTEGER"},
                        },
                        "required": ["mode"],
                    },
                    "programmation": {
                        "type": "OBJECT",
                        "properties": {
                            "heure": {"type": "STRING"},
                            "jours": {"type": "ARRAY", "items": {"type": "INTEGER"}},
                            "montee_minutes": {"type": "INTEGER"},
                            "paysage": {"type": "STRING"},
                            "rappel": {"type": "STRING", "enum": ["dormir", "detente"]},
                        },
                    },
                    "selecteur": {
                        "type": "OBJECT",
                        "properties": {
                            "id": {"type": "STRING"},
                            "heure": {"type": "STRING"},
                            "rappel": {"type": "STRING", "enum": ["dormir", "detente"]},
                            "moment_journee": {
                                "type": "STRING",
                                "enum": ["matin", "apres-midi", "soir"],
                            },
                        },
                    },
                    "cle": {
                        "type": "STRING",
                        "enum": [
                            "taille_texte",
                            "contraste_renforce",
                            "ecran_noir_minuteur",
                            "wifi_seulement",
                        ],
                    },
                    "raison": {
                        "type": "STRING",
                        "enum": ["incompris", "ambigu", "hors_catalogue", "interdit"],
                    },
                },
                "required": ["op"],
            },
        }
    },
    "required": ["actions"],
}

INSTRUCTION = """Tu règles l'application Eventide (sons de nature pour se détendre et dormir) \
à partir d'une phrase en français. Tu ne réponds JAMAIS par du texte libre : uniquement \
{"actions": [...]} selon le schéma imposé.

Opérations permises (champ « op », « cible » et valeurs) :
- definir paysage (valeur_texte = id de paysage) ; \
changer paysage (valeur_texte = suivant | precedent)
- definir moment (valeur_texte = aube | jour | soir | nuit)
- ajouter son|musique|decor (id, niveau 0-100 facultatif) ; retirer (id, ou "*" pour tous)
- regler (id, niveau 0-100) ; ajuster (id, delta de -100 à 100 : « baisse » = -20, « monte » = +20)
- couper son|musique : met toute la catégorie en sourdine en GARDANT ses éléments et leurs \
niveaux (« coupe la musique », « arrête la musique », « mets la musique en sourdine », « coupe \
les sons de la nature ») ; remettre son|musique : enlève la sourdine (« remets la musique ») ; \
retirer musique "*" seulement pour « enlève / retire / supprime (toute) la musique » ; \
« coupe le son », « coupe tout » = lecture pause ; le décor n'a pas de sourdine
- definir minuteur (minuteur = {mode: duree, minutes 1-600} | {mode: nuit} | {mode: aucun})
- lecture (valeur_texte = pause | reprise)
- creer programmation (programmation = heure "HH:MM", jours 1=lundi..7=dimanche, \
montee_minutes 5, 10, 15..60 par pas de 5, paysage, rappel dormir|detente)
- modifier programmation (selecteur + programmation partielle) ; activer | desactiver | \
supprimer programmation (selecteur = un seul champ parmi id, heure, rappel, moment_journee)
- definir sommeil.suivi (valeur_booleen) ; commencer_nuit ; partager
- definir reglage (cle taille_texte : valeur_texte plus|moins ou valeur_nombre 0-2 ; \
cle contraste_renforce|ecran_noir_minuteur|wifi_seulement : valeur_booleen)
- ouvrir premium (ouvre l'écran, n'achète jamais)
- reformuler (raison incompris|ambigu) si la phrase est ambiguë ou incomprise
- refuser (raison hors_catalogue) pour une demande hors de l'application ; \
refuser (raison interdit) pour acheter, s'abonner, résilier ou supprimer le compte.

Règles : n'utilise QUE les id du catalogue ci-dessous ; les nombres sont déjà normalisés en \
chiffres ; en cas de doute, reformuler plutôt qu'agir ; jamais plus de 10 actions.

Catalogue (id : nom ; alias) :
"""


def _catalog_text() -> str:
    catalog = get_catalog()
    lines = []
    for title, section in (
        ("Paysages", "paysages"),
        ("Sons (cible son)", "sons"),
        ("Musiques (cible musique)", "musiques"),
        ("Décors (cible decor)", "decors"),
    ):
        lines.append(f"{title} :")
        for item in catalog.raw[section]:
            aliases = ", ".join(item.get("alias", []))
            lines.append(f"- {item['id']} : {item['nom']} ; {aliases}")
    return "\n".join(lines)


def system_instruction() -> str:
    return INSTRUCTION + _catalog_text()


def _layer_summary(items: Any) -> list[dict]:
    out = []
    for item in items if isinstance(items, list) else []:
        if isinstance(item, dict) and isinstance(item.get("id"), str):
            out.append({"id": item["id"][:40], "niveau": item.get("niveau")})
    return out[:12]


def _mute_summary(value: Any) -> dict:
    """``sourdine`` of the scene (contract § 1): two booleans, false when absent or invalid."""
    value = value if isinstance(value, dict) else {}
    return {key: value.get(key) is True for key in ("sons", "musique")}


def state_summary(state: dict) -> dict:
    """The part of the app state the model needs (ids and levels only)."""
    scene = state.get("scene") if isinstance(state.get("scene"), dict) else {}
    schedules = []
    for s in state.get("programmations") or []:
        if isinstance(s, dict):
            schedules.append(
                {k: s.get(k) for k in ("id", "heure", "jours", "rappel", "actif", "paysage")}
            )
    return {
        "paysage": scene.get("paysage"),
        "moment": scene.get("moment"),
        "sons": _layer_summary(scene.get("sons")),
        "musique": _layer_summary(scene.get("musique")),
        "decor": _layer_summary(scene.get("decor")),
        "sourdine": _mute_summary(scene.get("sourdine")),
        "minuteur": scene.get("minuteur"),
        "lecture": state.get("lecture"),
        "programmations": schedules[:20],
        "reglages": state.get("reglages"),
    }


def user_text(phrase: str, state: dict) -> str:
    summary = json.dumps(state_summary(state), ensure_ascii=False, separators=(",", ":"))
    return f"État actuel : {summary}\nPhrase : {phrase}"


def _value(op: str, target: Any, wire: dict) -> tuple[bool, Any]:
    if target == "minuteur":
        return "minuteur" in wire, wire.get("minuteur")
    if target == "programmation" and op in ("creer", "modifier"):
        return "programmation" in wire, wire.get("programmation")
    for key in ("valeur_booleen", "valeur_nombre", "valeur_texte"):
        if key in wire:
            return True, wire[key]
    return False, None


def to_contract_ops(wire_actions: Any) -> list[Any]:
    """Wire format -> contract § 3 operations (the validator checks them afterwards)."""
    if not isinstance(wire_actions, list):
        return []
    ops: list[Any] = []
    for wire in wire_actions:
        if not isinstance(wire, dict):
            ops.append(wire)
            continue
        op = {
            k: wire[k]
            for k in ("op", "cible", "id", "niveau", "delta", "cle", "raison")
            if k in wire
        }
        if "selecteur" in wire:
            op["selecteur"] = wire["selecteur"]
        present, value = _value(str(wire.get("op")), wire.get("cible"), wire)
        if present:
            op["valeur"] = value
        ops.append(op)
    return ops
