"""Strict validation of the assistant's operations (contract § 3 and § 3.1).

The same rules run in the app before applying a list (shared vectors:
``shared/test-vectors/ops-validation.json``). Pure function, deterministic, no I/O.

Order of the rules:
1. a list is expected (anything else counts as an empty list); only its first 10 items are read;
2. a forbidden operation (purchase, subscription, cancellation, account deletion) anywhere in the
   list replaces the WHOLE list by ``[{"op": "refuser", "raison": "interdit"}]``;
3. each item is checked against the table of § 3; an invalid item is dropped; unexpected fields
   are dropped; defaults are filled (``niveau`` 50, ``montee_minutes`` 10, ``rappel`` dormir);
4. on the free plan, an operation that asks for a Premium item is replaced, in place, by
   ``{"op": "ouvrir", "cible": "premium"}``;
5. exact duplicates are removed (first occurrence kept): one « ouvrir premium » at most;
6. an empty result becomes ``[{"op": "reformuler", "raison": "incompris"}]``.
"""

from __future__ import annotations

import json
import re
from typing import Any

from apps.core.catalog import MOMENTS, TARGET_SECTIONS, Catalog, get_catalog

MAX_INPUT_OPS = 10
PLANS = ("free", "monthly", "annual", "lifetime")

OPEN_PREMIUM = {"op": "ouvrir", "cible": "premium"}
FORBIDDEN = {"op": "refuser", "raison": "interdit"}
NOT_UNDERSTOOD = {"op": "reformuler", "raison": "incompris"}

FORBIDDEN_OPS = frozenset(
    {
        "acheter",
        "achat",
        "payer",
        "abonner",
        "s_abonner",
        "souscrire",
        "resilier",
        "desabonner",
        "se_desabonner",
        "rembourser",
        "supprimer_compte",
    }
)
FORBIDDEN_TARGETS = frozenset(
    {"compte", "abonnement", "achat", "paiement", "credits", "facturation"}
)

HOUR_RE = re.compile(r"^([01][0-9]|2[0-3]):[0-5][0-9]$")
SCHEDULE_FIELDS = ("heure", "jours", "montee_minutes", "paysage", "rappel")
RAMP_VALUES = frozenset({5, 10, *range(15, 61, 5)})
REMINDERS = ("dormir", "detente")
DAY_PARTS = ("matin", "apres-midi", "soir")
SETTING_BOOLEANS = ("contraste_renforce", "ecran_noir_minuteur", "wifi_seulement")
REPHRASE_REASONS = ("incompris", "ambigu")
REFUSAL_REASONS = ("hors_catalogue", "interdit")
MAX_SELECTOR_ID = 64
# ``couper`` / ``remettre`` (mute, ``sourdine``): sounds and music only, the decor has no mute.
MUTE_TARGETS = ("son", "musique")


class _Invalid(Exception):
    pass


class _Premium(Exception):
    pass


def _int(value: Any, low: int, high: int) -> int:
    # bool is an int in Python: refused, as in Dart.
    if isinstance(value, bool) or not isinstance(value, int) or not low <= value <= high:
        raise _Invalid
    return value


def _choice(value: Any, choices: tuple[str, ...] | frozenset[str]) -> str:
    if not isinstance(value, str) or value not in choices:
        raise _Invalid
    return value


def _bool(value: Any) -> bool:
    if not isinstance(value, bool):
        raise _Invalid
    return value


def _require_premium_ok(free: bool, catalog: Catalog, section: str, item_id: str) -> None:
    if free and not catalog.is_free(section, item_id):
        raise _Premium


def _landscape(value: Any, catalog: Catalog, free: bool) -> str:
    if not catalog.has("paysages", value):
        raise _Invalid
    _require_premium_ok(free, catalog, "paysages", value)
    return value


def _timer(value: Any) -> dict:
    if not isinstance(value, dict):
        raise _Invalid
    mode = value.get("mode")
    if mode == "duree":
        return {"mode": "duree", "minutes": _int(value.get("minutes"), 1, 600)}
    if mode in ("nuit", "aucun"):
        return {"mode": mode}
    raise _Invalid


def _days(value: Any) -> list[int]:
    if not isinstance(value, list) or not value:
        raise _Invalid
    return sorted({_int(day, 1, 7) for day in value})


def _schedule_fields(value: Any, catalog: Catalog, free: bool, *, partial: bool) -> dict:
    if not isinstance(value, dict):
        raise _Invalid
    out: dict[str, Any] = {}
    premium = False
    if "heure" in value:
        if not isinstance(value["heure"], str) or not HOUR_RE.match(value["heure"]):
            raise _Invalid
        out["heure"] = value["heure"]
    if "jours" in value:
        out["jours"] = _days(value["jours"])
    if "montee_minutes" in value:
        ramp = value["montee_minutes"]
        if isinstance(ramp, bool) or not isinstance(ramp, int) or ramp not in RAMP_VALUES:
            raise _Invalid
        out["montee_minutes"] = ramp
    if "paysage" in value:
        try:
            out["paysage"] = _landscape(value["paysage"], catalog, free)
        except _Premium:
            premium = True
    if "rappel" in value:
        out["rappel"] = _choice(value["rappel"], REMINDERS)
    if not partial:
        if "heure" not in out or "jours" not in out:
            raise _Invalid
        out.setdefault("montee_minutes", 10)
        out.setdefault("rappel", "dormir")
    elif not out and not premium:
        raise _Invalid
    if premium:  # checked last: an invalid field wins over a Premium landscape
        raise _Premium
    return out


def _selector(value: Any) -> dict:
    if not isinstance(value, dict):
        raise _Invalid
    keys = [k for k in ("id", "heure", "rappel", "moment_journee") if k in value]
    if len(keys) != 1:
        raise _Invalid
    key = keys[0]
    item = value[key]
    if key == "id":
        if not isinstance(item, str) or not 1 <= len(item) <= MAX_SELECTOR_ID:
            raise _Invalid
    elif key == "heure":
        if not isinstance(item, str) or not HOUR_RE.match(item):
            raise _Invalid
    elif key == "rappel":
        _choice(item, REMINDERS)
    else:
        _choice(item, DAY_PARTS)
    return {key: item}


def _layer_op(op: str, raw: dict, catalog: Catalog, free: bool) -> dict:
    target = raw.get("cible")
    if target not in TARGET_SECTIONS:
        raise _Invalid
    section = TARGET_SECTIONS[target]
    item_id = raw.get("id")
    if op == "retirer":
        if item_id != "*" and not catalog.has(section, item_id):
            raise _Invalid
        return {"op": op, "cible": target, "id": item_id}
    if not catalog.has(section, item_id):
        raise _Invalid
    if op == "ajouter":
        level = _int(raw["niveau"], 0, 100) if "niveau" in raw else 50
        out = {"op": op, "cible": target, "id": item_id, "niveau": level}
    elif op == "regler":
        out = {"op": op, "cible": target, "id": item_id, "niveau": _int(raw.get("niveau"), 0, 100)}
    else:  # ajuster
        out = {"op": op, "cible": target, "id": item_id, "delta": _int(raw.get("delta"), -100, 100)}
    _require_premium_ok(free, catalog, section, item_id)
    return out


def _mute_op(op: str, raw: dict) -> dict:
    """``couper`` / ``remettre`` a whole category; every other field is dropped."""
    return {"op": op, "cible": _choice(raw.get("cible"), MUTE_TARGETS)}


def _definir(raw: dict, catalog: Catalog, free: bool) -> dict:
    target = raw.get("cible")
    value = raw.get("valeur")
    if target == "paysage":
        return {"op": "definir", "cible": "paysage", "valeur": _landscape(value, catalog, free)}
    if target == "moment":
        return {"op": "definir", "cible": "moment", "valeur": _choice(value, MOMENTS)}
    if target == "minuteur":
        return {"op": "definir", "cible": "minuteur", "valeur": _timer(value)}
    if target == "sommeil.suivi":
        return {"op": "definir", "cible": "sommeil.suivi", "valeur": _bool(value)}
    if target == "reglage":
        key = raw.get("cle")
        if key == "taille_texte":
            if value in ("plus", "moins"):
                return {"op": "definir", "cible": "reglage", "cle": key, "valeur": value}
            return {"op": "definir", "cible": "reglage", "cle": key, "valeur": _int(value, 0, 2)}
        return {
            "op": "definir",
            "cible": "reglage",
            "cle": _choice(key, SETTING_BOOLEANS),
            "valeur": _bool(value),
        }
    raise _Invalid


def _schedule_op(op: str, raw: dict, catalog: Catalog, free: bool) -> dict:
    if raw.get("cible") != "programmation":
        raise _Invalid
    if op == "creer":
        value = _schedule_fields(raw.get("valeur"), catalog, free, partial=False)
        return {"op": op, "cible": "programmation", "valeur": value}
    selector = _selector(raw.get("selecteur"))
    if op == "modifier":
        value = _schedule_fields(raw.get("valeur"), catalog, free, partial=True)
        return {"op": op, "cible": "programmation", "selecteur": selector, "valeur": value}
    return {"op": op, "cible": "programmation", "selecteur": selector}


def _one(raw: Any, catalog: Catalog, free: bool) -> dict:
    if not isinstance(raw, dict):
        raise _Invalid
    op = raw.get("op")
    if not isinstance(op, str):
        raise _Invalid
    if op in ("ajouter", "retirer", "regler", "ajuster"):
        return _layer_op(op, raw, catalog, free)
    if op in ("couper", "remettre"):
        return _mute_op(op, raw)
    if op == "definir":
        return _definir(raw, catalog, free)
    if op == "changer":
        if raw.get("cible") != "paysage":
            raise _Invalid
        return {
            "op": "changer",
            "cible": "paysage",
            "valeur": _choice(raw.get("valeur"), ("suivant", "precedent")),
        }
    if op == "lecture":
        return {"op": "lecture", "valeur": _choice(raw.get("valeur"), ("pause", "reprise"))}
    if op in ("creer", "modifier", "activer", "desactiver", "supprimer"):
        return _schedule_op(op, raw, catalog, free)
    if op in ("commencer_nuit", "partager"):
        return {"op": op}
    if op == "ouvrir":
        if raw.get("cible") != "premium":
            raise _Invalid
        return dict(OPEN_PREMIUM)
    if op == "reformuler":
        reason = raw.get("raison")
        return {"op": "reformuler", "raison": reason if reason in REPHRASE_REASONS else "incompris"}
    if op == "refuser":
        reason = raw.get("raison")
        return {
            "op": "refuser",
            "raison": reason if reason in REFUSAL_REASONS else "hors_catalogue",
        }
    raise _Invalid


def _is_forbidden(raw: Any) -> bool:
    if not isinstance(raw, dict):
        return False
    op = raw.get("op")
    target = raw.get("cible")
    if isinstance(op, str) and op in FORBIDDEN_OPS:
        return True
    if isinstance(target, str) and target in FORBIDDEN_TARGETS:
        return True
    # Premium can only be « opened » (the screen), never activated or bought by voice.
    return target == "premium" and isinstance(op, str) and op != "ouvrir"


def validate_ops(ops_in: Any, plan: str, catalog: Catalog | None = None) -> list[dict]:
    """Validated, normalised list of operations (never empty)."""
    if plan not in PLANS:
        raise ValueError(f"unknown plan {plan!r}")
    catalog = catalog or get_catalog()
    items = ops_in[:MAX_INPUT_OPS] if isinstance(ops_in, list) else []
    if any(_is_forbidden(raw) for raw in items):
        return [dict(FORBIDDEN)]
    free = plan == "free"
    result: list[dict] = []
    seen: set[str] = set()
    for raw in items:
        try:
            op = _one(raw, catalog, free)
        except _Premium:
            op = dict(OPEN_PREMIUM)
        except (_Invalid, KeyError, TypeError):
            continue
        key = json.dumps(op, sort_keys=True, ensure_ascii=False)
        if key in seen:
            continue
        seen.add(key)
        result.append(op)
    return result or [dict(NOT_UNDERSTOOD)]
