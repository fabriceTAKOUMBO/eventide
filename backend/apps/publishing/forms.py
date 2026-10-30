"""Dashboard forms (contract § 14): new element, edit."""

from __future__ import annotations

import re
from typing import Any

from django import forms

from .catalog import AMBIANCE_PREFIX, base_ids, current_catalog
from .models import PublishedItem

Kind = PublishedItem.Kind

ID_RE = re.compile(r"[a-z0-9]+(-[a-z0-9]+)*")
ALIAS_MAX = 10
ALIAS_LEN = 40
CONTROL_RE = re.compile(r"[\x00-\x1f\x7f<>]")
EXTRA_SOUNDS = 3
EXTRA_MUSIC = 2
DEFAULT_SOUND_LEVEL = 35
DEFAULT_MUSIC_LEVEL = 20

GRATUIT_CHOICES = [("premium", "Premium"), ("gratuit", "Gratuit")]
THEME_CHOICES = [("nature", "Nature"), ("urbain", "Urbain")]


def _text(value: str) -> str:
    return " ".join(value.split())


def parse_aliases(raw: str) -> list[str]:
    """Comma-separated, lower case, without duplicates, 10 at most (contract § 14)."""
    out: list[str] = []
    for part in raw.split(","):
        alias = _text(part).lower()
        if not alias:
            continue
        if len(alias) > ALIAS_LEN or CONTROL_RE.search(alias):
            raise forms.ValidationError(f"Un alias fait {ALIAS_LEN} caractères au plus.")
        if alias not in out:
            out.append(alias)
    if len(out) > ALIAS_MAX:
        raise forms.ValidationError(f"{ALIAS_MAX} alias au plus.")
    return out


def mix_choices() -> tuple[list[tuple[str, str]], list[tuple[str, str]]]:
    """Sounds and music a landscape's default mix may add (published catalog; no other
    landscape's ambiance)."""
    catalog = current_catalog()
    sounds = [("", "—")] + [(s["id"], s["nom"]) for s in catalog.raw["sons"] if "paysage" not in s]
    music = [("", "—")] + [(m["id"], m["nom"]) for m in catalog.raw["musiques"]]
    return sounds, music


class _NameFields(forms.Form):
    nom = forms.CharField(label="Nom", min_length=2, max_length=40, strip=True)
    gratuit = forms.ChoiceField(
        label="Accès", choices=GRATUIT_CHOICES, widget=forms.RadioSelect, initial="premium"
    )
    alias = forms.CharField(label="Alias", required=False, max_length=600, strip=True)

    def clean_nom(self) -> str:
        nom = _text(self.cleaned_data["nom"])
        if not 2 <= len(nom) <= 40 or CONTROL_RE.search(nom):
            raise forms.ValidationError("Le nom fait de 2 à 40 caractères.")
        return nom

    def clean_alias(self) -> list[str]:
        return parse_aliases(self.cleaned_data.get("alias") or "")

    def values(self) -> dict[str, Any]:
        data = self.cleaned_data
        return {"nom": data["nom"], "alias": data["alias"], "gratuit": data["gratuit"] == "gratuit"}


class EditForm(_NameFields):
    pass


class NewElementForm(_NameFields):
    kind = forms.ChoiceField(label="Type", choices=Kind.choices, widget=forms.RadioSelect)
    item_id = forms.CharField(label="Identifiant", min_length=3, max_length=40, strip=True)
    theme = forms.ChoiceField(label="Thème", choices=THEME_CHOICES, required=False)
    eclairs = forms.BooleanField(label="Éclairs d'orage", required=False)

    def __init__(self, *args: Any, **kwargs: Any):
        super().__init__(*args, **kwargs)
        sounds, music = mix_choices()
        for i in range(1, EXTRA_SOUNDS + 1):
            self.fields[f"son_{i}"] = forms.ChoiceField(choices=sounds, required=False)
            self.fields[f"niveau_son_{i}"] = forms.IntegerField(
                min_value=1, max_value=100, required=False, initial=DEFAULT_SOUND_LEVEL
            )
        for i in range(1, EXTRA_MUSIC + 1):
            self.fields[f"musique_{i}"] = forms.ChoiceField(choices=music, required=False)
            self.fields[f"niveau_musique_{i}"] = forms.IntegerField(
                min_value=1, max_value=100, required=False, initial=DEFAULT_MUSIC_LEVEL
            )

    def clean_item_id(self) -> str:
        value = self.cleaned_data["item_id"]
        if not 3 <= len(value) <= 40 or not ID_RE.fullmatch(value):
            raise forms.ValidationError(
                "De 3 à 40 caractères : lettres minuscules, chiffres et tirets entre les mots."
            )
        if value.startswith(AMBIANCE_PREFIX):
            raise forms.ValidationError("« ambiance- » est réservé aux ambiances des paysages.")
        reserved = base_ids()
        if value in reserved or f"{AMBIANCE_PREFIX}{value}" in reserved:
            raise forms.ValidationError("Cet identifiant est déjà pris par le catalogue de base.")
        if PublishedItem.objects.filter(item_id=value).exists():
            raise forms.ValidationError("Cet identifiant est déjà pris (même retiré).")
        return value

    def _layer(self, prefix: str, count: int) -> list[dict[str, Any]]:
        layer, seen = [], set()
        for i in range(1, count + 1):
            item_id = self.cleaned_data.get(f"{prefix}_{i}") or ""
            if not item_id:
                continue
            level = self.cleaned_data.get(f"niveau_{prefix}_{i}")
            if level is None:
                self.add_error(f"niveau_{prefix}_{i}", "Niveau de 1 à 100.")
                continue
            if item_id in seen:
                self.add_error(f"{prefix}_{i}", "Déjà dans le mix.")
                continue
            seen.add(item_id)
            layer.append({"id": item_id, "niveau": level})
        return layer

    def clean(self) -> dict[str, Any]:
        data = super().clean()
        if data.get("kind") == Kind.PAYSAGE:
            if not data.get("theme"):
                self.add_error("theme", "Choisissez Nature ou Urbain.")
            data["mix"] = {
                "sons": self._layer("son", EXTRA_SOUNDS),
                "musique": self._layer("musique", EXTRA_MUSIC),
            }
        else:
            data["theme"] = ""
            data["eclairs"] = False
            data["mix"] = {}
        return data

    def values(self) -> dict[str, Any]:
        data = self.cleaned_data
        return {
            **super().values(),
            "kind": data["kind"],
            "item_id": data["item_id"],
            "theme": data["theme"],
            "eclairs": bool(data["eclairs"]),
            "mix": data["mix"],
        }
