#!/usr/bin/env bash
# Runs inside reactivecircus/android-emulator-runner (.github/workflows/app.yml), from app/,
# against one booted emulator. Three stages, all logs and screenshots in <out-dir>:
#
#   A. Release demo APK (R8, x86_64): install, launch with `am start -W`, the process stays
#      alive, demo mode is on, no FATAL EXCEPTION / ANR / Dart error in logcat; screenshots.
#   B. Integration test (integration_test/demo_flow_test.dart, debug demo build) with
#      `flutter drive --keep-app-running`; it leaves a schedule armed two to three minutes ahead.
#   C. Scheduled start on a real Android system: the alarm is registered (dumpsys alarm), the
#      app goes to the background (HOME), the alarm fires; which path ran is recorded: media
#      foreground service (and whether the sound started) or the « Lancer » fallback notification.
#
# A and B decide the exit code. C writes « pass » or « fail » to <out-dir>/scheduled-start.status
# and its findings to <out-dir>/scheduled-start.txt (read by a non-blocking workflow step).
#
# Usage: emulator_checks.sh <release-demo-x86_64.apk> <out-dir>
set -uo pipefail

release_apk="${1:?usage: $0 <release-demo-apk> <out-dir>}"
out="${2:?usage: $0 <release-demo-apk> <out-dir>}"
pkg="${DEMO_PACKAGE:-be.cinaf.eventide.demo}"
mkdir -p "$out"
out="$(cd "$out" && pwd)"
export PATH="${ANDROID_HOME:-${ANDROID_SDK_ROOT:-/usr/local/lib/android/sdk}}/platform-tools:$PATH"
summary="${GITHUB_STEP_SUMMARY:-/dev/null}"

log() { echo "[emulator-checks $(date -u +%H:%M:%S)] $*"; }
# Every adb call is bounded: an emulator that dies must fail the job, not leave
# `adb` waiting for the device until the workflow timeout (seen on 28 Oct 2026: 60 min hang).
adb() { timeout "${ADB_TIMEOUT:-120}" command adb "$@"; }
device_alive() { [[ "$(timeout 20 command adb get-state 2>/dev/null | tr -d '\r')" == "device" ]]; }
# Host-side clues when the emulator disappears (memory pressure, emulator crash).
host_diagnostics() {
  log "host diagnostics ($1)"
  free -m || true
  ps -eo pid,rss,comm --sort=-rss | head -n 8 || true
  (sudo -n dmesg -T 2>/dev/null || dmesg -T 2>/dev/null || true) | grep -iE 'out of memory|killed process|oom' | tail -n 10 || true
  ls -la /tmp/android-runner 2>/dev/null | tail -n 5 || true
}
annotate() { [[ -n "${GITHUB_ACTIONS:-}" ]] && echo "::$1 title=Emulator API ${api:-?}::$2"; return 0; }
shot() { adb exec-out screencap -p >"$out/$1.png" 2>/dev/null || log "screenshot $1 failed"; }
device_ms() { echo $(( $(adb shell date +%s | tr -d '\r') * 1000 )); }

grant() {
  # Exact alarms (denied by default on Android 14+ for new installs) and notifications.
  adb shell appops set "$pkg" SCHEDULE_EXACT_ALARM allow >/dev/null 2>&1 || true
  adb shell pm grant "$pkg" android.permission.POST_NOTIFICATIONS >/dev/null 2>&1 || true
}

# Crash patterns in a `logcat -v brief` dump, for our process only. Prints the offending lines.
# ALLOWED_FLUTTER_ERRORS (extended regex, empty by default) can exempt a known-harmless engine
# line, e.g. a graphics backend fallback message of the emulator's software GPU.
find_crashes() {
  local file="$1" allowed="${ALLOWED_FLUTTER_ERRORS:-}"
  grep -A 3 'FATAL EXCEPTION' "$file" | grep -B 1 -A 2 "Process: $pkg" || true
  grep -E "ANR in $pkg" "$file" || true
  if [[ -n "$allowed" ]]; then
    grep -E '^E/flutter' "$file" | grep -Ev "$allowed" || true
  else
    grep -E '^E/flutter' "$file" || true
  fi
  grep -E '^[IE]/flutter.*(EXCEPTION CAUGHT BY|Another exception was thrown|Unhandled Exception)' "$file" || true
}

adb wait-for-device
serial="$(adb devices | awk 'NR > 1 && $2 == "device" { print $1; exit }')"
api="$(adb shell getprop ro.build.version.sdk | tr -d '\r')"
release="$(adb shell getprop ro.build.version.release | tr -d '\r')"
size="$(adb shell wm size | tr -d '\r' | sed 's/.*: //' | tail -n 1)"
density="$(adb shell wm density | tr -d '\r' | sed 's/.*: //' | tail -n 1)"
log "device $serial: Android $release (API $api), screen $size @ ${density} dpi"
{
  echo "### Emulator: Android $release (API $api), $size, ${density} dpi"
  echo
} >>"$summary"

status_a="fail"
status_b="fail"

# ---------------------------------------------------------------------------------------------
# A. Release demo APK
# ---------------------------------------------------------------------------------------------
stage_a() {
  log "A. release demo APK: $release_apk"
  adb uninstall "$pkg" >/dev/null 2>&1 || true
  if ! timeout 300 adb install -r "$release_apk" >"$out/a-install.txt" 2>&1; then
    cat "$out/a-install.txt"
    annotate error "A: the release demo APK does not install"
    return 1
  fi
  grant
  adb logcat -c
  local component
  component="$(adb shell cmd package resolve-activity --brief -c android.intent.category.LAUNCHER "$pkg" | tr -d '\r' | tail -n 1)"
  [[ "$component" == */* ]] || component="$pkg/be.cinaf.eventide.MainActivity"
  log "A. launching $component"
  timeout 180 adb shell am start -W -n "$component" | tr -d '\r' | tee "$out/a-am-start.txt"
  sleep 4
  shot a-1-launch
  sleep 12
  shot a-2-after-16s
  local pid
  pid="$(adb shell pidof "$pkg" | tr -d '\r')"
  adb logcat -d -v brief >"$out/a-logcat.txt"
  local crashes ok=0
  crashes="$(find_crashes "$out/a-logcat.txt")"
  if ! grep -q 'Status: ok' "$out/a-am-start.txt"; then
    annotate error "A: am start did not report « Status: ok »"
    ok=1
  fi
  if [[ -z "$pid" ]]; then
    annotate error "A: the release demo app is not running 16 s after launch (crash?)"
    ok=1
  fi
  if [[ -n "$crashes" ]]; then
    echo "$crashes" | head -n 60
    # Full first stack trace with its causes in the job log (artifacts may not be reachable).
    grep -m 1 -A 60 'FATAL EXCEPTION' "$out/a-logcat.txt" | grep -E 'FATAL|Process:|Exception|Error|Caused by|at ' | head -n 40 || true
    annotate error "A: crash, ANR or Dart error in logcat (see a-logcat.txt): $(echo "$crashes" | head -n 1)"
    ok=1
  fi
  if ! grep -q 'Eventide: demo mode on' "$out/a-logcat.txt"; then
    annotate error "A: « Eventide: demo mode on » missing from logcat: the release demo build did not enter demo mode"
    ok=1
  fi
  local total
  total="$(sed -n 's/^TotalTime: //p' "$out/a-am-start.txt")"
  echo "| A. Release demo APK (R8) | $([[ $ok -eq 0 ]] && echo OK || echo '**FAIL**') | pid ${pid:-none}, cold start ${total:-?} ms |" >>"$out/rows.md"
  adb shell am force-stop "$pkg" || true
  # The debug build of stage B is signed with another key: start from a clean install.
  adb uninstall "$pkg" >/dev/null 2>&1 || true
  return "$ok"
}

# ---------------------------------------------------------------------------------------------
# B. Integration test (flutter drive, debug demo build)
# ---------------------------------------------------------------------------------------------
stage_b() {
  log "B. integration test with flutter drive"
  # Install the prebuilt debug APK first (same package and key as what flutter drive installs
  # with `adb install -r`), so that permissions are granted before the first launch.
  local debug_apk="build/app/outputs/flutter-apk/app-debug.apk"
  if [[ -f "$debug_apk" ]]; then
    adb install -r "$debug_apk" >"$out/b-preinstall.txt" 2>&1 || cat "$out/b-preinstall.txt"
  fi
  grant
  # Keeps granting while flutter drive (re)installs the app (idempotent).
  (while true; do
    if adb shell pm path "$pkg" >/dev/null 2>&1; then grant; fi
    sleep 3
  done) &
  local granter=$!
  adb logcat -c
  local code=0
  # Reuse the APK built before the emulator started: no Gradle build (and no 3 GB daemon)
  # competing with the emulator for memory while the test runs.
  local prebuilt=()
  if [[ -f "$debug_apk" ]]; then prebuilt=(--use-application-binary "$debug_apk"); fi
  timeout 1200 flutter drive -d "$serial" \
    "${prebuilt[@]}" \
    --driver=test_driver/integration_test.dart \
    --target=integration_test/demo_flow_test.dart \
    --dart-define=DEMO_MODE=true \
    --android-project-arg=eventide.demo=true \
    --keep-app-running \
    --screenshot "$out/b-failure-screenshot" 2>&1 | tee "$out/b-flutter-drive.txt"
  code=${PIPESTATUS[0]}
  kill "$granter" 2>/dev/null || true
  wait "$granter" 2>/dev/null || true
  if ! device_alive; then
    host_diagnostics "device lost during stage B"
    annotate error "B: the emulator disconnected during the integration test (see host diagnostics in the job log)"
    echo "| B. Integration test (debug demo) | **FAIL** | emulator lost |" >>"$out/rows.md"
    return 1
  fi
  shot b-after-flow
  adb logcat -d -v brief >"$out/b-logcat.txt"
  grep -o 'EVENTIDE_IT .*' "$out/b-logcat.txt" | sed 's/\r$//' >"$out/b-report.txt" || true
  cat "$out/b-report.txt"
  grep 'EventideSchedule' "$out/b-logcat.txt" | tail -n 5 || true
  local crashes
  crashes="$(grep -A 3 'FATAL EXCEPTION' "$out/b-logcat.txt" | grep -B 1 -A 2 "Process: $pkg" || true; grep -E "ANR in $pkg" "$out/b-logcat.txt" || true)"
  if [[ -n "$crashes" ]]; then
    echo "$crashes" | head -n 40
    annotate error "B: crash or ANR during the integration test (see b-logcat.txt)"
    code=1
  fi
  if [[ $code -ne 0 ]]; then
    annotate error "B: integration test failed (exit $code, see b-flutter-drive.txt)"
  fi
  local audio
  audio="$(grep -o 'audio=[a-z]*' "$out/b-report.txt" | tail -n 1)"
  echo "| B. Integration test (debug demo) | $([[ $code -eq 0 ]] && echo OK || echo '**FAIL**') | ${audio:-audio=?}, $(grep -o 'alarm_mode=[a-z]*' "$out/b-report.txt" | tail -n 1) |" >>"$out/rows.md"
  return "$code"
}

# ---------------------------------------------------------------------------------------------
# C. Scheduled start (app in background)
# ---------------------------------------------------------------------------------------------
stage_c() {
  if ! device_alive; then
    log "C. skipped: no device"
    echo fail >"$out/scheduled-start.status"
    echo "emulator unavailable, scheduled start not tested" >"$out/scheduled-start.txt"
    echo "| C. Scheduled start (background) | **SKIPPED** | emulator unavailable |" >>"$out/rows.md"
    return 0
  fi
  log "C. scheduled start"
  local result="$out/scheduled-start.txt"
  : >"$result"
  local at_ms
  at_ms="$(grep -o 'schedule_at_ms=[0-9]*' "$out/b-report.txt" 2>/dev/null | tail -n 1 | cut -d= -f2)"
  if [[ -z "$at_ms" ]]; then
    echo "no schedule was created by the integration test" | tee -a "$result"
    echo fail >"$out/scheduled-start.status"
    echo "| C. Scheduled start | **FAIL** | no schedule from stage B |" >>"$out/rows.md"
    return 0
  fi
  adb shell dumpsys alarm >"$out/c-dumpsys-alarm-before.txt" 2>&1
  local registered="no" armed_log
  if grep -q 'be.cinaf.eventide.action.SCHEDULE_FIRE' "$out/c-dumpsys-alarm-before.txt" &&
    grep -q "$pkg" "$out/c-dumpsys-alarm-before.txt"; then
    registered="yes"
  fi
  armed_log="$(grep 'EventideSchedule' "$out/b-logcat.txt" | grep 'armed:' | tail -n 1 | sed 's/.*armed: //')"
  {
    echo "alarm registered in dumpsys alarm: $registered"
    echo "last arming (Kotlin): ${armed_log:-not logged}"
    echo "dumpsys alarm, our package:"
    grep -B 1 -A 6 "$pkg" "$out/c-dumpsys-alarm-before.txt" | head -n 40 | sed 's/^/    /'
  } >>"$result"

  adb logcat -c
  adb shell input keyevent KEYCODE_HOME
  sleep 2
  shot c-1-home
  local now_ms deadline
  now_ms="$(device_ms)"
  deadline=$((at_ms + 100000))
  log "C. app in background; schedule at $at_ms, device now $now_ms (in $(((at_ms - now_ms) / 1000)) s)"
  local seen=""
  while (($(device_ms) < deadline)); do
    adb logcat -d -v brief >"$out/c-logcat.txt"
    if grep -Eq 'EventideSchedule.*(playback started for schedule|nothing played for schedule|fallback|no-connection|skipped|nothing to start)' "$out/c-logcat.txt"; then
      seen="yes"
      sleep 8 # let the service and the notification settle
      break
    fi
    sleep 5
  done
  shot c-2-after-fire
  adb logcat -d -v brief >"$out/c-logcat.txt"
  adb shell dumpsys activity services "$pkg" >"$out/c-dumpsys-services.txt" 2>&1
  adb shell dumpsys media_session >"$out/c-dumpsys-media-session.txt" 2>&1
  adb shell dumpsys notification --noredact >"$out/c-dumpsys-notification.txt" 2>&1
  adb shell dumpsys alarm >"$out/c-dumpsys-alarm-after.txt" 2>&1

  local fired="no" service="no" fallback="no" sound="unknown" running="no" foreground="no" notif="no" session=""
  grep -q 'EventideSchedule.*alarm fired' "$out/c-logcat.txt" && fired="yes"
  grep -q 'EventideSchedule.*foreground media service start requested' "$out/c-logcat.txt" && service="yes"
  grep -q 'EventideSchedule.*fallback.*posted=true' "$out/c-logcat.txt" && fallback="yes"
  if grep -q 'EventideSchedule: playback started for schedule' "$out/c-logcat.txt"; then
    sound="started"
  elif grep -q 'EventideSchedule: nothing played for schedule' "$out/c-logcat.txt"; then
    sound="not started (audio output unavailable?)"
  fi
  grep -q 'com.ryanheise.audioservice.AudioService' "$out/c-dumpsys-services.txt" && running="yes"
  grep -q 'isForeground=true' "$out/c-dumpsys-services.txt" && foreground="yes"
  grep -q "pkg=$pkg" "$out/c-dumpsys-notification.txt" && notif="yes"
  session="$(grep -A 12 "package=$pkg" "$out/c-dumpsys-media-session.txt" | grep -m 1 -o 'state=PlaybackState {state=[0-9]*' || true)"

  local path="none"
  if [[ $fired == "yes" && $service == "yes" ]]; then
    path="foreground media service"
  elif [[ $fired == "yes" && $fallback == "yes" ]]; then
    path="« Lancer » fallback notification"
  elif [[ $fired == "no" ]]; then
    path="alarm did not fire"
  fi
  {
    echo "receiver fired: $fired (log seen while waiting: ${seen:-no})"
    echo "path: $path"
    echo "foreground service start requested: $service"
    echo "fallback notification posted: $fallback"
    echo "sound (Dart handler): $sound"
    echo "AudioService in dumpsys activity services: $running (isForeground=true: $foreground)"
    echo "media session of $pkg: ${session:-not found}"
    echo "notification of $pkg in dumpsys notification: $notif"
    echo "logcat EventideSchedule lines:"
    grep 'EventideSchedule' "$out/c-logcat.txt" | sed 's/^/    /'
  } >>"$result"
  cat "$result"
  if [[ $fired == "yes" && ($service == "yes" || $fallback == "yes") ]]; then
    echo pass >"$out/scheduled-start.status"
    echo "| C. Scheduled start (background) | OK | $path; sound: $sound |" >>"$out/rows.md"
  else
    echo fail >"$out/scheduled-start.status"
    echo "| C. Scheduled start (background) | **FAIL** | $path; registered: $registered |" >>"$out/rows.md"
  fi
  return 0
}

: >"$out/rows.md"
stage_a && status_a="ok"
stage_b && status_b="ok"
stage_c
{
  echo "| Stage | Result | Details |"
  echo "|---|---|---|"
  cat "$out/rows.md"
  echo
  echo "<details><summary>Scheduled start (API $api)</summary>"
  echo
  echo '```'
  cat "$out/scheduled-start.txt" 2>/dev/null
  echo '```'
  echo "</details>"
  echo
} >>"$summary"
log "A: $status_a, B: $status_b, C: $(cat "$out/scheduled-start.status" 2>/dev/null || echo fail)"
[[ $status_a == "ok" && $status_b == "ok" ]]
