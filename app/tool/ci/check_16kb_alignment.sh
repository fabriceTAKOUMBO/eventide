#!/usr/bin/env bash
# Checks that APKs are ready for 16 KB memory pages (Android 15+ devices; Google Play requires it
# for apps targeting API 35+):
#   1. every 64-bit native library (lib/arm64-v8a, lib/x86_64) has all its ELF LOAD segments
#      aligned on at least 16 KB (0x4000);
#   2. the APK itself passes `zipalign -c -P 16 -v 4` (uncompressed libraries 16 KB aligned in
#      the zip, so Android can map them in place).
#
# Usage: check_16kb_alignment.sh [--no-zipalign] <apk>...
# Tools: READELF and ZIPALIGN may be given in the environment; otherwise llvm-readelf from the
# Android NDK (or readelf from binutils) and zipalign from the newest Android build-tools (35+
# for -P) are used.
set -euo pipefail

min_align=16384
run_zipalign=1
if [[ "${1:-}" == "--no-zipalign" ]]; then
  run_zipalign=0
  shift
fi
if [[ $# -eq 0 ]]; then
  echo "usage: $0 [--no-zipalign] <apk>..." >&2
  exit 2
fi

annotate() { # level message
  if [[ -n "${GITHUB_ACTIONS:-}" ]]; then
    echo "::$1 title=16 KB page alignment::$2"
  fi
}

find_readelf() {
  if [[ -n "${READELF:-}" ]]; then
    echo "$READELF"
    return
  fi
  local ndk candidate
  for ndk in "${ANDROID_NDK_LATEST_HOME:-}" "${ANDROID_NDK_HOME:-}" "${ANDROID_NDK_ROOT:-}"; do
    candidate="$ndk/toolchains/llvm/prebuilt/linux-x86_64/bin/llvm-readelf"
    if [[ -n "$ndk" && -x "$candidate" ]]; then
      echo "$candidate"
      return
    fi
  done
  if [[ -n "${ANDROID_HOME:-}" && -d "$ANDROID_HOME/ndk" ]]; then
    candidate="$(find "$ANDROID_HOME/ndk" -path '*/linux-x86_64/bin/llvm-readelf' 2>/dev/null | sort -V | tail -n 1)"
    if [[ -n "$candidate" ]]; then
      echo "$candidate"
      return
    fi
  fi
  command -v llvm-readelf || command -v readelf || true
}

find_zipalign() {
  if [[ -n "${ZIPALIGN:-}" ]]; then
    echo "$ZIPALIGN"
    return
  fi
  local sdk="${ANDROID_HOME:-${ANDROID_SDK_ROOT:-}}"
  [[ -n "$sdk" && -d "$sdk/build-tools" ]] || return 0
  local dir version
  # `zipalign -P` (page alignment) exists since build-tools 35.
  for dir in $(find "$sdk/build-tools" -mindepth 1 -maxdepth 1 -type d | sort -V -r); do
    version="$(basename "$dir")"
    if [[ "${version%%.*}" =~ ^[0-9]+$ && "${version%%.*}" -ge 35 && -x "$dir/zipalign" ]]; then
      echo "$dir/zipalign"
      return
    fi
  done
}

readelf_bin="$(find_readelf)"
if [[ -z "$readelf_bin" ]]; then
  echo "ERROR: neither llvm-readelf (Android NDK) nor readelf found." >&2
  exit 2
fi
echo "readelf: $readelf_bin"
zipalign_bin=""
if [[ $run_zipalign -eq 1 ]]; then
  zipalign_bin="$(find_zipalign)"
  if [[ -z "$zipalign_bin" ]]; then
    echo "ERROR: zipalign from Android build-tools 35+ not found (set ZIPALIGN or ANDROID_HOME)." >&2
    exit 2
  fi
  echo "zipalign: $zipalign_bin"
fi

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

failures=0
summary="${GITHUB_STEP_SUMMARY:-/dev/null}"
{
  echo "### 16 KB page alignment"
  echo
  echo "| APK | Library | Smallest LOAD alignment | Result |"
  echo "|---|---|---|---|"
} >>"$summary"

for apk in "$@"; do
  if [[ ! -f "$apk" ]]; then
    echo "ERROR: $apk does not exist." >&2
    failures=$((failures + 1))
    continue
  fi
  name="$(basename "$apk")"
  dest="$work/$name"
  mkdir -p "$dest"
  # unzip exits with 11 when a pattern matches nothing (e.g. an arm64-only APK).
  unzip -q -o "$apk" 'lib/arm64-v8a/*.so' 'lib/x86_64/*.so' -d "$dest" || [[ $? -eq 11 ]]
  mapfile -t libs < <(find "$dest/lib" -name '*.so' 2>/dev/null | sort)
  echo
  echo "== $name: ${#libs[@]} 64-bit native libraries"
  if [[ ${#libs[@]} -eq 0 ]]; then
    echo "ERROR: $name has no lib/arm64-v8a or lib/x86_64 library (libflutter.so is always expected)." >&2
    annotate error "$name: no 64-bit native library found"
    failures=$((failures + 1))
    continue
  fi
  for lib in "${libs[@]}"; do
    rel="${lib#"$dest"/}"
    mapfile -t aligns < <("$readelf_bin" -lW "$lib" | awk '$1 == "LOAD" { print $NF }')
    if [[ ${#aligns[@]} -eq 0 ]]; then
      echo "  FAIL  $rel: no LOAD segment found (not an ELF shared library?)"
      annotate error "$name: $rel has no LOAD segment"
      echo "| $name | $rel | none | FAIL |" >>"$summary"
      failures=$((failures + 1))
      continue
    fi
    smallest=""
    for a in "${aligns[@]}"; do
      if [[ ! "$a" =~ ^0x[0-9a-fA-F]+$ ]]; then
        echo "  FAIL  $rel: unexpected alignment value '$a'"
        smallest="0"
        break
      fi
      if [[ -z "$smallest" ]] || (( a < smallest )); then
        smallest=$((a))
      fi
    done
    hex="$(printf '0x%x' "$smallest")"
    if (( smallest >= min_align )); then
      echo "  OK    $rel (LOAD align $hex)"
      echo "| $name | $rel | $hex | OK |" >>"$summary"
    else
      echo "  FAIL  $rel: LOAD segments aligned on $hex, 16 KB (0x4000) required"
      annotate error "$name: $rel has LOAD segments aligned on $hex (16 KB = 0x4000 required). Rebuild it with -Wl,-z,max-page-size=16384 or update the plugin that ships it."
      echo "| $name | $rel | $hex | **FAIL** |" >>"$summary"
      failures=$((failures + 1))
    fi
  done

  if [[ $run_zipalign -eq 1 ]]; then
    log="$work/$name.zipalign.txt"
    if "$zipalign_bin" -c -P 16 -v 4 "$apk" >"$log" 2>&1; then
      echo "  OK    zipalign -c -P 16 -v 4"
      echo "| $name | (zip) | zipalign -P 16 | OK |" >>"$summary"
    else
      echo "  FAIL  zipalign -c -P 16 -v 4 $name:"
      grep -E 'BAD|ERROR|error' "$log" | head -n 40 | sed 's/^/        /' || tail -n 20 "$log"
      bad="$(grep -E '\.so .*BAD' "$log" | awk '{print $2}' | tr '\n' ' ' || true)"
      annotate error "$name fails zipalign -c -P 16 (16 KB zip alignment). Offending entries: ${bad:-see log}"
      echo "| $name | (zip) ${bad:-} | zipalign -P 16 | **FAIL** |" >>"$summary"
      failures=$((failures + 1))
    fi
  fi
done

echo
if [[ $failures -gt 0 ]]; then
  echo "16 KB page alignment: $failures problem(s). Android 15+ phones with 16 KB pages (and Google Play) refuse such libraries."
  exit 1
fi
echo "16 KB page alignment: all 64-bit native libraries and APK zip alignment are OK."
