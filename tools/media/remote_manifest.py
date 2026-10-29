"""``app/assets/landscapes/remote.json``: what the content server (S3, ``content/``) holds.

The app only asks ``POST /content/urls`` for keys listed here, so it never requests a missing
file (contract § 8 and § 11):

  * ``videos`` / ``images``: Premium landscapes with ``videos/paysages/<id>.mp4`` /
    ``images/paysages/<id>.jpg``;
  * ``sons`` / ``musiques``: every ``audio/sons/<id>.ogg`` / ``audio/musiques/<id>.ogg``,
    including the landscape ambiances and the variants of the event sounds (``tonnerre-01``...).
    A sound that is neither bundled nor listed (e.g. a test-only ambiance, demo build only) is
    left out of the mix by the app, without an error message.

Rewritten by every tool that writes into ``content/`` (process_video.py, make_ambiance.py,
generate_audio.py).
"""

from __future__ import annotations

import json
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
CONTENT_DIR = REPO / "content"
REMOTE_MANIFEST = REPO / "app" / "assets" / "landscapes" / "remote.json"


def _ids(folder: Path, ext: str) -> list[str]:
    return sorted(f.stem for f in folder.glob(f"*{ext}")) if folder.exists() else []


def write_remote_manifest() -> dict:
    manifest = {
        "version": 1,
        "videos": _ids(CONTENT_DIR / "videos" / "paysages", ".mp4"),
        "images": _ids(CONTENT_DIR / "images" / "paysages", ".jpg"),
        "sons": _ids(CONTENT_DIR / "audio" / "sons", ".ogg"),
        "musiques": _ids(CONTENT_DIR / "audio" / "musiques", ".ogg"),
    }
    REMOTE_MANIFEST.parent.mkdir(parents=True, exist_ok=True)
    REMOTE_MANIFEST.write_text(json.dumps(manifest, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    return manifest
