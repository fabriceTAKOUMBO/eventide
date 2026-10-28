"""``rules-only`` router: a few unambiguous phrases, matched exactly after normalisation.

The full rules engine (hours, numbers, « septante ») lives in the app; this server-side
router is the free fallback chosen by configuration (e.g. if the model is withdrawn).
"""

from __future__ import annotations

import re
import unicodedata

from .base import RouterResult

PHRASES: dict[str, list[dict]] = {
    "pause": [{"op": "lecture", "valeur": "pause"}],
    "mets en pause": [{"op": "lecture", "valeur": "pause"}],
    "reprends": [{"op": "lecture", "valeur": "reprise"}],
    "reprise": [{"op": "lecture", "valeur": "reprise"}],
    "continue": [{"op": "lecture", "valeur": "reprise"}],
    "commence la nuit": [{"op": "commencer_nuit"}],
    "coupe la musique": [{"op": "couper", "cible": "musique"}],
    "mets la musique en sourdine": [{"op": "couper", "cible": "musique"}],
    "remets la musique": [{"op": "remettre", "cible": "musique"}],
    "coupe les sons de la nature": [{"op": "couper", "cible": "son"}],
    "remets les sons de la nature": [{"op": "remettre", "cible": "son"}],
    "partage mon mix": [{"op": "partager"}],
    "passe moi en premium": [{"op": "ouvrir", "cible": "premium"}],
    "sans minuteur": [{"op": "definir", "cible": "minuteur", "valeur": {"mode": "aucun"}}],
    "toute la nuit": [{"op": "definir", "cible": "minuteur", "valeur": {"mode": "nuit"}}],
    "change de paysage": [{"op": "changer", "cible": "paysage", "valeur": "suivant"}],
    "il fait nuit": [{"op": "definir", "cible": "moment", "valeur": "nuit"}],
    "mets le soir": [{"op": "definir", "cible": "moment", "valeur": "soir"}],
    "active le suivi du sommeil": [{"op": "definir", "cible": "sommeil.suivi", "valeur": True}],
    "mets le texte plus grand": [
        {"op": "definir", "cible": "reglage", "cle": "taille_texte", "valeur": "plus"}
    ],
    "supprime mon compte": [{"op": "refuser", "raison": "interdit"}],
}


def normalise(phrase: str) -> str:
    text = unicodedata.normalize("NFKD", phrase.lower())
    text = "".join(c for c in text if not unicodedata.combining(c))
    text = re.sub(r"[^a-z0-9]+", " ", text)
    return re.sub(r"\s+", " ", text).strip()


class RulesRouter:
    name = "rules-only"

    def route(self, *, phrase: str, state: dict) -> RouterResult:
        actions = PHRASES.get(normalise(phrase), [{"op": "reformuler", "raison": "incompris"}])
        return RouterResult(actions=[dict(a) for a in actions], model="rules-only")
