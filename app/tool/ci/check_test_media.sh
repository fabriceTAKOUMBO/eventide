#!/usr/bin/env bash
# medias-test/ holds third-party material (YouTube) for the product owner's internal tests only:
# NON-DISTRIBUTABLE. Only the demo build copies it into its assets, at build time
# (tool/ci/bundle_demo_media.sh). This check fails when any of it is committed where a
# distributed build or the content server would pick it up: under content/ (S3) or app/assets/
# (every APK), whether by name (videos/paysages/<id>.mp4, images/paysages/<id>.jpg, and the
# ambiances audio/sons/<id>.ogg made from their soundtrack) or as an identical file anywhere in
# those trees.
#
# Usage: check_test_media.sh [repo-root]   (run on a clean checkout, before any demo copy)
set -euo pipefail

repo="${1:-$(cd "$(dirname "$0")/../../.." && pwd)}"
test_dir="$repo/medias-test"

fail() {
  echo "FAIL: $*" >&2
  if [[ -n "${GITHUB_ACTIONS:-}" ]]; then
    echo "::error title=Test-only media::$*"
  fi
  exit 1
}

if [[ ! -d "$test_dir" ]]; then
  echo "no medias-test/ folder: nothing to check"
  exit 0
fi

shopt -s nullglob
problems=()

# 1. By name: a test landscape video or poster where the content server or an APK takes it.
for video in "$test_dir"/videos/paysages/*.mp4; do
  id="$(basename "$video" .mp4)"
  for target in "content/videos/paysages/$id.mp4" "app/assets/landscapes/$id.mp4"; do
    [[ -e "$repo/$target" ]] && problems+=("$target (same landscape as medias-test/videos/paysages/$id.mp4)")
  done
done
for poster in "$test_dir"/images/paysages/*.jpg; do
  id="$(basename "$poster" .jpg)"
  for target in "content/images/paysages/$id.jpg" "app/assets/landscapes/$id.jpg"; do
    [[ -e "$repo/$target" ]] && problems+=("$target (same landscape as medias-test/images/paysages/$id.jpg)")
  done
done

for sound in "$test_dir"/audio/sons/*.ogg; do
  id="$(basename "$sound" .ogg)"
  for target in "content/audio/sons/$id.ogg" "app/assets/audio/sons/$id.ogg"; do
    [[ -e "$repo/$target" ]] && problems+=("$target (same ambiance as medias-test/audio/sons/$id.ogg)")
  done
done

# 2. By content: any file of medias-test/ (originals and processed loops) copied elsewhere.
declare -A test_hashes=()
while IFS= read -r -d '' file; do
  [[ "$(basename "$file")" == "LISEZMOI.md" ]] && continue
  test_hashes["$(sha256sum "$file" | cut -d' ' -f1)"]="${file#"$repo"/}"
done < <(find "$test_dir" -type f -print0)

for tree in content app/assets; do
  [[ -d "$repo/$tree" ]] || continue
  while IFS= read -r -d '' file; do
    hash="$(sha256sum "$file" | cut -d' ' -f1)"
    if [[ -n "${test_hashes[$hash]:-}" ]]; then
      problems+=("${file#"$repo"/} (identical to ${test_hashes[$hash]})")
    fi
  done < <(find "$repo/$tree" -type f \( -name '*.mp4' -o -name '*.jpg' -o -name '*.jpeg' -o -name '*.png' -o -name '*.webm' -o -name '*.mov' -o -name '*.ogg' \) -print0)
done

echo "medias-test/: ${#test_hashes[@]} file(s), checked against content/ and app/assets/"
if ((${#problems[@]} > 0)); then
  printf '  %s\n' "${problems[@]}" >&2
  fail "test-only third-party media (medias-test/, non-distributable) found under content/ or app/assets/: ${problems[*]}"
fi
echo "  OK: none under content/ or app/assets/"
