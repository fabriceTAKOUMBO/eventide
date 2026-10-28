"""Shared vectors: the API and the Flutter app must give the same result for each case."""

import json
from pathlib import Path

import pytest
from django.conf import settings

from apps.voice.validator import validate_ops

VECTORS = Path(settings.BASE_DIR).parent / "shared" / "test-vectors" / "ops-validation.json"
CASES = json.loads(VECTORS.read_text(encoding="utf-8"))


def test_vector_file_is_well_formed():
    assert len(CASES) >= 40
    names = [c["name"] for c in CASES]
    assert len(names) == len(set(names)), "case names must be unique"
    for case in CASES:
        assert set(case) == {"name", "plan", "ops_in", "ops_out"}
        assert case["plan"] in ("free", "monthly", "annual", "lifetime")
        assert case["ops_out"], "the validator never returns an empty list"


@pytest.mark.parametrize("case", CASES, ids=[c["name"] for c in CASES])
def test_vector(case):
    assert validate_ops(case["ops_in"], case["plan"]) == case["ops_out"]
