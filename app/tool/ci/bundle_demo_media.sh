#!/usr/bin/env bash
# DEMO BUILD ONLY (« Eventide Démo »): copies into app/assets/ what production never bundles,
# so that the demo works without the API:
#   - the Premium sounds and music (content/audio/{sons,musiques}/*.ogg -> assets/audio/...);
#   - the Premium landscape videos and posters (content/videos/paysages/*.mp4 and
#     content/images/paysages/*.jpg -> assets/landscapes/);
#   - the third-party TEST-ONLY landscape videos and posters (medias-test/videos/paysages/*.mp4
#     and medias-test/images/paysages/*.jpg -> assets/landscapes/) and their ambiances
#     (medias-test/audio/sons/*.ogg -> assets/audio/sons/): non-distributable, for the product
#     owner's internal tests on their own phone, to be removed before any beta.
# The Premium sounds include the landscape ambiances and the variants of the event sounds
# (tonnerre-01.ogg...: contract § 11).
# Never run it before a production build; never commit what it copies
# (git checkout -- assets && git clean -f assets).
#
# Usage (from app/): bash tool/ci/bundle_demo_media.sh
# No network, no credential: local file copies only.
set -euo pipefail

app="$(cd "$(dirname "$0")/../.." && pwd)"
repo="$(cd "$app/.." && pwd)"
shopt -s nullglob

copy() {
  local dest="$1"
  shift
  mkdir -p "$dest"
  if (($# > 0)); then
    cp "$@" "$dest/"
  fi
  echo "  $(($#)) file(s) -> ${dest#"$app"/}"
}

echo "Demo media (never in the production build):"
copy "$app/assets/audio/sons" "$repo"/content/audio/sons/*.ogg
copy "$app/assets/audio/musiques" "$repo"/content/audio/musiques/*.ogg
copy "$app/assets/landscapes" "$repo"/content/videos/paysages/*.mp4 "$repo"/content/images/paysages/*.jpg
copy "$app/assets/landscapes" "$repo"/medias-test/videos/paysages/*.mp4 "$repo"/medias-test/images/paysages/*.jpg
copy "$app/assets/audio/sons" "$repo"/medias-test/audio/sons/*.ogg
