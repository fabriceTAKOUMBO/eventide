#!/usr/bin/env bash
# Checks what a release APK is, so that the demo build can never pass for production:
#   production: package be.cinaf.eventide, label « Full Relax », free audio (with the free
#               landscape ambiance) and free landscape videos only: no Premium audio (the Premium
#               ambiances and the thunder variants tonnerre-<part>-NN included), no Premium landscape
#               video or poster (content/videos, content/images: served by the API), and none of
#               the third-party test-only media (medias-test/, non-distributable);
#   both:       SCHEDULE_EXACT_ALARM declared and never USE_EXACT_ALARM (Play policy);
#               the poster of every « Imaginaire » landscape (assets/landscapes/<id>.jpg) and the
#               loop of the free one (foret-lucioles.mp4), and no live 3D runtime any more
#               (assets/imaginaire/ absent: the « Imaginaire » landscapes are videos since
#               10 November 2026, contract § 12);
#   demo:       package be.cinaf.eventide.demo, label « Full Relax Démo », every Premium sound and
#               music of content/audio, every landscape video and poster of content/ (the loops of
#               the Premium « Imaginaire » landscapes included) and of medias-test/, and the
#               test-only ambiances of medias-test/audio bundled.
#
# Usage: check_apk_contents.sh production|demo <apk> [content-audio-dir]
# Needs unzip, python3 (reads app/assets/catalog.json) and aapt2 (newest Android build-tools
# under ANDROID_HOME, or AAPT2=...).
set -euo pipefail

kind="${1:?usage: $0 production|demo <apk> [content-audio-dir]}"
apk="${2:?usage: $0 production|demo <apk> [content-audio-dir]}"
repo="$(cd "$(dirname "$0")/../../.." && pwd)"
content="${3:-$repo/content/audio}"

case "$kind" in
  production)
    want_package="be.cinaf.eventide"
    want_label="Full Relax"
    ;;
  demo)
    want_package="be.cinaf.eventide.demo"
    want_label="Full Relax Démo"
    ;;
  *)
    echo "unknown kind '$kind' (production or demo)" >&2
    exit 2
    ;;
esac

fail() {
  echo "FAIL: $*" >&2
  if [[ -n "${GITHUB_ACTIONS:-}" ]]; then
    echo "::error title=APK contents ($kind)::$*"
  fi
  exit 1
}

[[ -f "$apk" ]] || fail "$apk does not exist"
[[ -d "$content/sons" && -d "$content/musiques" ]] || fail "no Premium audio folder at $content"

aapt2_bin="${AAPT2:-}"
if [[ -z "$aapt2_bin" ]]; then
  sdk="${ANDROID_HOME:-${ANDROID_SDK_ROOT:-}}"
  if [[ -n "$sdk" && -d "$sdk/build-tools" ]]; then
    aapt2_bin="$(find "$sdk/build-tools" -mindepth 2 -maxdepth 2 -name aapt2 | sort -V | tail -n 1)"
  fi
fi
[[ -n "$aapt2_bin" && -x "$aapt2_bin" ]] || fail "aapt2 not found (set AAPT2 or ANDROID_HOME)"

echo "== $(basename "$apk") ($kind)"
badging="$("$aapt2_bin" dump badging "$apk")"
package="$(sed -n "s/^package: name='\([^']*\)'.*/\1/p" <<<"$badging" | head -n 1)"
label="$(sed -n "s/^application-label:'\(.*\)'$/\1/p" <<<"$badging" | head -n 1)"
echo "  package: $package"
echo "  label:   $label"
grep -E "^(sdkVersion|minSdkVersion|targetSdkVersion):" <<<"$badging" | sed 's/^/  /' || true
[[ "$package" == "$want_package" ]] || fail "package is '$package', expected '$want_package'"
[[ "$label" == "$want_label" ]] || fail "launcher label is '$label', expected '$want_label'"
# Scheduled starts: SCHEDULE_EXACT_ALARM (asked from « Alarmes et rappels » when a schedule is
# saved), never USE_EXACT_ALARM (Google Play keeps it for alarm clock and calendar apps).
grep -q "^uses-permission: name='android.permission.SCHEDULE_EXACT_ALARM'" <<<"$badging" \
  || fail "the APK does not declare SCHEDULE_EXACT_ALARM (scheduled starts)"
! grep -q "^uses-permission: name='android.permission.USE_EXACT_ALARM'" <<<"$badging" \
  || fail "the APK declares USE_EXACT_ALARM (Play policy: alarm clock and calendar apps only)"

manifest="$("$aapt2_bin" dump xmltree --file AndroidManifest.xml "$apk" 2>/dev/null || true)"
demo_flag="$(grep -A 2 'be.cinaf.eventide.DEMO_BUILD' <<<"$manifest" | grep 'android:value' | head -n 1 | sed 's/^ *//' || true)"
echo "  DEMO_BUILD meta-data: ${demo_flag:-not found}"

listing="$(unzip -Z1 "$apk")"
prefix="assets/flutter_assets/assets/audio"
grep -qx "$prefix/sons/eau-vive.ogg" <<<"$listing" || fail "free sound eau-vive.ogg missing from the APK"
# The ambiance of the free landscape (the sound of its video, contract § 11) is bundled.
grep -qx "$prefix/sons/ambiance-cascade-foret.ogg" <<<"$listing" \
  || fail "free landscape ambiance ambiance-cascade-foret.ogg missing from the APK"
premium=0
missing=()
for file in "$content"/sons/*.ogg "$content"/musiques/*.ogg; do
  folder="$(basename "$(dirname "$file")")"
  entry="$prefix/$folder/$(basename "$file")"
  if grep -qx "$entry" <<<"$listing"; then
    premium=$((premium + 1))
  else
    missing+=("$entry")
  fi
done
total=$(( $(find "$content/sons" "$content/musiques" -name '*.ogg' | wc -l) ))
echo "  Premium audio bundled: $premium / $total"

if [[ "$kind" == "production" ]]; then
  [[ $premium -eq 0 ]] || fail "the production APK contains $premium Premium audio file(s) (e.g. $prefix/sons/vagues.ogg); they are served by the API, never bundled"
else
  [[ ${#missing[@]} -eq 0 ]] || fail "the demo APK lacks Premium audio: ${missing[*]}"
fi

# Living landscapes: assets/landscapes/<id>.mp4 (loop) and <id>.jpg (its frame 0).
lprefix="assets/flutter_assets/assets/landscapes"
for free in cascade-foret.mp4 cascade-foret.jpg foret-lucioles.mp4 foret-lucioles.jpg remote.json; do
  grep -qx "$lprefix/$free" <<<"$listing" || fail "free landscape media $free missing from the APK"
done
shopt -s nullglob

# « Imaginaire » (contract § 12, 10 November 2026): its landscapes are videos rendered offline from
# our 3D scenes (tools/imaginaire/). The live 3D runtime (assets/imaginaire/: WebView page,
# three.js, scenes) must be absent from every APK. Every APK bundles the poster of each of them
# (free users see the Premium tiles too) and the loop of the free ones; the demo bundles the loops
# of the Premium ones too (content/videos, bundle_demo_media.sh), production never.
imaginaire_runtime="$(grep -E '^assets/flutter_assets/assets/imaginaire/' <<<"$listing" || true)"
[[ -z "$imaginaire_runtime" ]] \
  || fail "the APK still contains the live 3D runtime (assets/imaginaire/): $(head -n 3 <<<"$imaginaire_runtime" | tr '\n' ' ')"
command -v python3 >/dev/null || fail "python3 is needed to read app/assets/catalog.json"
# "<id> free|premium" for each landscape of the « Imaginaire » theme, in catalog order.
imaginaire="$(python3 - "$repo/app/assets/catalog.json" <<'PY'
import json, sys
catalog = json.load(open(sys.argv[1], encoding="utf-8"))
for landscape in catalog["paysages"]:
    if landscape.get("theme") == "imaginaire":
        print(landscape["id"], "free" if landscape.get("gratuit") is True else "premium")
PY
)"
[[ -n "$imaginaire" ]] || fail "no « Imaginaire » landscape in app/assets/catalog.json"
imaginaire_count=0
imaginaire_premium_loops=0
while read -r id plan; do
  imaginaire_count=$((imaginaire_count + 1))
  grep -qx "$lprefix/$id.jpg" <<<"$listing" || fail "poster of the « Imaginaire » landscape $id ($id.jpg) missing from the APK"
  if [[ "$plan" == "free" ]]; then
    grep -qx "$lprefix/$id.mp4" <<<"$listing" || fail "loop of the free « Imaginaire » landscape $id ($id.mp4) missing from the APK"
  elif [[ "$kind" == "production" ]]; then
    ! grep -qx "$lprefix/$id.mp4" <<<"$listing" \
      || fail "the production APK contains the Premium « Imaginaire » loop $id.mp4 (served by the API)"
  else
    [[ -f "$repo/content/videos/paysages/$id.mp4" ]] \
      || fail "no loop for the Premium « Imaginaire » landscape $id under content/videos/paysages"
    grep -qx "$lprefix/$id.mp4" <<<"$listing" || fail "the demo APK lacks the Premium « Imaginaire » loop $id.mp4"
    imaginaire_premium_loops=$((imaginaire_premium_loops + 1))
  fi
done <<<"$imaginaire"
echo "  « Imaginaire »: $imaginaire_count posters bundled, Premium loops bundled: $imaginaire_premium_loops, live 3D runtime: none"
check_media() {
  local label="$1"
  shift
  local present=() absent=() file entry
  for file in "$@"; do
    entry="$lprefix/$(basename "$file")"
    if grep -qx "$entry" <<<"$listing"; then present+=("$entry"); else absent+=("$entry"); fi
  done
  echo "  $label bundled: ${#present[@]} / $#"
  if [[ "$kind" == "production" ]]; then
    [[ ${#present[@]} -eq 0 ]] || fail "the production APK contains $label: ${present[*]}"
  else
    [[ ${#absent[@]} -eq 0 ]] || fail "the demo APK lacks $label: ${absent[*]}"
  fi
}
check_media "Premium landscape videos/posters (content/)" \
  "$repo"/content/videos/paysages/*.mp4 "$repo"/content/images/paysages/*.jpg
check_media "test-only third-party videos/posters (medias-test/, non-distributable)" \
  "$repo"/medias-test/videos/paysages/*.mp4 "$repo"/medias-test/images/paysages/*.jpg

# Test-only ambiances (the soundtrack of the third-party test videos): demo only.
test_audio=()
for file in "$repo"/medias-test/audio/sons/*.ogg; do
  entry="$prefix/sons/$(basename "$file")"
  grep -qx "$entry" <<<"$listing" && test_audio+=("$entry")
done
total_test_audio=$(( $(find "$repo/medias-test/audio/sons" -name '*.ogg' 2>/dev/null | wc -l) ))
echo "  test-only ambiances (medias-test/audio, non-distributable) bundled: ${#test_audio[@]} / $total_test_audio"
if [[ "$kind" == "production" ]]; then
  [[ ${#test_audio[@]} -eq 0 ]] || fail "the production APK contains test-only audio: ${test_audio[*]}"
else
  [[ ${#test_audio[@]} -eq $total_test_audio ]] || fail "the demo APK lacks test-only ambiances (${#test_audio[@]} / $total_test_audio)"
fi
echo "  OK"
