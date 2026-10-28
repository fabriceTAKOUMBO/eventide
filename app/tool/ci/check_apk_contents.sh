#!/usr/bin/env bash
# Checks what a release APK is, so that the demo build can never pass for production:
#   production: package be.cinaf.eventide, label « Eventide », free audio only (no Premium audio);
#   demo:       package be.cinaf.eventide.demo, label « Eventide Démo », every Premium sound and
#               music of content/audio bundled.
#
# Usage: check_apk_contents.sh production|demo <apk> [content-audio-dir]
# Needs unzip and aapt2 (newest Android build-tools under ANDROID_HOME, or AAPT2=...).
set -euo pipefail

kind="${1:?usage: $0 production|demo <apk> [content-audio-dir]}"
apk="${2:?usage: $0 production|demo <apk> [content-audio-dir]}"
content="${3:-$(cd "$(dirname "$0")/../../.." && pwd)/content/audio}"

case "$kind" in
  production)
    want_package="be.cinaf.eventide"
    want_label="Eventide"
    ;;
  demo)
    want_package="be.cinaf.eventide.demo"
    want_label="Eventide Démo"
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

manifest="$("$aapt2_bin" dump xmltree --file AndroidManifest.xml "$apk" 2>/dev/null || true)"
demo_flag="$(grep -A 2 'be.cinaf.eventide.DEMO_BUILD' <<<"$manifest" | grep 'android:value' | head -n 1 | sed 's/^ *//' || true)"
echo "  DEMO_BUILD meta-data: ${demo_flag:-not found}"

listing="$(unzip -Z1 "$apk")"
prefix="assets/flutter_assets/assets/audio"
grep -qx "$prefix/sons/eau-vive.ogg" <<<"$listing" || fail "free sound eau-vive.ogg missing from the APK"
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
echo "  OK"
