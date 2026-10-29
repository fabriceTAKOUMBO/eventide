#!/usr/bin/env bash
# Runs inside reactivecircus/android-emulator-runner (.github/workflows/app.yml), from app/,
# against one booted emulator. Three stages, all logs and screenshots in <out-dir>:
#
#   A. Release demo APK (R8, x86_64): install, launch with `am start -W`, then wait (up to
#      A_READY_TIMEOUT s from the launch) until the first frame is drawn and demo mode is on,
#      and watch the app for A_SETTLE more seconds: it stays alive, no FATAL EXCEPTION / ANR /
#      Dart error in logcat; screenshots. `am start -W` gives up after about 10 s: « Status:
#      timeout » is accepted only when ActivityTaskManager reports « Displayed <package>/… »
#      (first frame drawn) later on, the process alive and no crash.
#   B. Integration test (integration_test/demo_flow_test.dart, debug demo build) with
#      `flutter drive --keep-app-running`; it leaves a schedule armed two to three minutes ahead.
#   C. Scheduled start on a real Android system: the alarm is registered (dumpsys alarm), the
#      app goes to the background (HOME), the alarm fires; which path ran is recorded: media
#      foreground service (and whether the sound started) or the « Lancer » fallback notification.
#
# A and B decide the exit code. C writes « pass » or « fail » to <out-dir>/scheduled-start.status
# and its findings to <out-dir>/scheduled-start.txt (read by a non-blocking workflow step).
#
# The whole guest log is streamed to a host file during each stage, and the emulator process is
# sampled every MONITOR_INTERVAL seconds (host-monitor.txt: memory, threads, CPU used during the
# interval). An emulator that stops using the CPU while alive is stuck, or crashed and is being
# core-dumped: its threads (state, kernel wait channel, gdb backtraces or the fatal signal when gdb
# is installed) are dumped once to emulator-freeze.txt. When the emulator disappears, the job log shows that dump, the host
# samples and kernel log, any emulator crash report, and a digest of the guest log (our app's
# lines, crashes, watchdog, audio, media codecs, graphics) followed by its last lines.
#
# Optional environment: EMULATOR_WM_SIZE / EMULATOR_WM_DENSITY (display override applied before
# stage A), A_READY_TIMEOUT (120), A_SETTLE (15), AM_START_TIMEOUT (60), ALLOWED_FLUTTER_ERRORS.
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
demo_marker='Eventide: demo mode on'
# Reference time for the host files written during this step (emulator crash reports).
: >"$out/.step-start"

log() { echo "[emulator-checks $(date -u +%H:%M:%S)] $*"; }
# Every adb call is bounded: an emulator that dies must fail the job, not leave
# `adb` waiting for the device until the workflow timeout (seen on 28 Oct 2026: 60 min hang).
# (`timeout` runs a program: it needs adb's path, not the `command` shell builtin.)
ADB_BIN="$(command -v adb || echo adb)"
adb() { timeout "${ADB_TIMEOUT:-120}" "$ADB_BIN" "$@"; }
device_alive() { [[ "$(timeout 20 "$ADB_BIN" get-state 2>/dev/null | tr -d '\r')" == "device" ]]; }

# ---- Background helpers: guest log stream and host monitor (stopped on exit).
stream_pid=""
monitor_pid=""
stop_logcat_stream() {
  [[ -n $stream_pid ]] || return 0
  kill "$stream_pid" 2>/dev/null || true
  wait "$stream_pid" 2>/dev/null || true
  stream_pid=""
}
# Streams the whole guest log (all buffers, with timestamps) to a host file while a stage runs:
# when the emulator disappears, the lines written up to that moment are kept.
start_logcat_stream() {
  stop_logcat_stream
  timeout "${STREAM_TIMEOUT:-2400}" "$ADB_BIN" logcat -v threadtime -b all >"$1" 2>&1 &
  stream_pid=$!
}
# Threads of an emulator that stopped using the CPU, once: id, state, kernel wait channel,
# name, then gdb backtraces (`sudo gdb`, when installed: ptrace of a non-child needs root).
# A thread in do_coredump means the emulator crashed and the kernel is writing its core dump
# (about 50 s for 4 GB, seen on 28 Oct 2026); gdb then names the signal.
freeze_dump() {
  local pid="$1" file="$out/emulator-freeze.txt" task state threads crashed
  threads="$(for task in /proc/"$pid"/task/*; do
    state="$(sed 's/^.*) //' "$task/stat" 2>/dev/null | cut -d' ' -f1)"
    printf '%s %s %s %s\n' "${task##*/}" "$state" "$(cat "$task/wchan" 2>/dev/null)" "$(cat "$task/comm" 2>/dev/null)"
  done)"
  crashed="$(awk '$3 == "do_coredump" {print $4}' <<<"$threads" | sort -u | paste -sd, -)"
  {
    if [[ -n $crashed ]]; then
      echo "emulator pid $pid CRASHED: thread(s) « $crashed » writing a core dump ($(date -u +%H:%M:%S))"
    else
      echo "emulator pid $pid used no CPU for three samples in a row ($(date -u +%H:%M:%S)): stuck"
    fi
    echo "threads (tid, state, kernel wait channel, name):"
    echo "$threads"
    if command -v gdb >/dev/null; then
      echo "--- gdb backtraces (12 frames per thread)"
      timeout 120 sudo -n gdb -batch -nx -p "$pid" -ex 'set pagination off' -ex 'thread apply all bt 12' 2>&1 |
        grep -vE '^\[New LWP|^warning: |^Downloading|^$'
    else
      echo "(gdb not installed: no backtraces)"
    fi
    echo "--- end of the freeze dump"
  } >"$file" 2>&1
}
# Emulator process every MONITOR_INTERVAL seconds: memory, threads, CPU used during the interval
# (not ps's lifetime average), host load and memory; a frozen emulator is dumped once.
start_host_monitor() {
  (
    interval="${MONITOR_INTERVAL:-5}"
    hz="$(getconf CLK_TCK 2>/dev/null || echo 100)"
    prev_pid="" prev_ticks=0 still=0 dumped=""
    while :; do
      pid="$(pgrep -f 'qemu-system' 2>/dev/null | head -n 1)"
      if [[ -n $pid && -r /proc/$pid/stat ]]; then
        read -r -a fields < <(sed 's/^.*) //' "/proc/$pid/stat")
        ticks=$((fields[11] + fields[12]))
        cpu="?"
        if [[ $pid == "$prev_pid" ]]; then cpu=$(((ticks - prev_ticks) * 100 / (hz * interval))); fi
        prev_pid="$pid"
        prev_ticks="$ticks"
        emu="$(awk '/^VmRSS/ {r = $2} /^Threads/ {t = $2} END {printf "rss %d MB, %s threads", r / 1024, t}' "/proc/$pid/status")"
        emu="emulator pid $pid $emu, cpu ${cpu}% over ${interval} s; "
        # A live guest always uses some CPU; a deadlocked emulator uses none (seen: 0 for 40 s).
        if [[ $cpu != "?" && $cpu -lt 1 ]]; then still=$((still + 1)); else still=0; fi
        if [[ $still -ge 3 && -z $dumped ]]; then
          dumped="yes"
          emu="${emu}no CPU for $((3 * interval)) s, threads dumped to emulator-freeze.txt; "
          freeze_dump "$pid"
        fi
      else
        emu="no emulator process; "
      fi
      printf '%s %sload %s; %s\n' "$(date -u +%H:%M:%S)" "$emu" \
        "$(cut -d' ' -f1-3 /proc/loadavg 2>/dev/null)" \
        "$(free -m 2>/dev/null | awk 'NR == 2 {printf "host memory used %s available %s MB", $3, $7}')"
      sleep "$interval"
    done
  ) >>"$out/host-monitor.txt" 2>&1 &
  monitor_pid=$!
}
cleanup() {
  stop_logcat_stream
  [[ -n $monitor_pid ]] && kill "$monitor_pid" 2>/dev/null
  return 0
}
trap cleanup EXIT

# Host-side clues when the emulator disappears: is its process still there, its last memory and
# CPU samples, the host kernel log (OOM killer, segfault), emulator crash reports, and the last
# guest log lines before the loss ($2: stream file).
host_diagnostics() {
  log "host diagnostics ($1)"
  if pgrep -af 'qemu-system' 2>/dev/null | cut -c1-160; then
    echo "the emulator process is still running (adb lost the device)"
  else
    echo "no emulator process on the host any more: the emulator exited"
  fi
  free -m || true
  echo "load average: $(cut -d' ' -f1-3 /proc/loadavg 2>/dev/null)"
  ps -eo pid,rss,pcpu,comm --sort=-rss | head -n 8 || true
  if [[ -s $out/host-monitor.txt ]]; then
    echo "--- host monitor (every ${MONITOR_INTERVAL:-5} s), last samples"
    tail -n 12 "$out/host-monitor.txt"
  fi
  echo "--- host kernel log, last lines"
  (sudo -n dmesg -T 2>/dev/null || dmesg -T 2>/dev/null || true) | tail -n 25
  echo "--- files written under /tmp/android-runner during this step (emulator crash reports, netsim)"
  find /tmp/android-runner -newer "$out/.step-start" -type f -printf '%TT %9s %p\n' 2>/dev/null |
    sort | tail -n 20 || true
  find /tmp/android-runner/netsimd -maxdepth 2 -type f \( -name '*.log' -o -name '*std*' \) 2>/dev/null |
    head -n 3 | while read -r file; do
      echo "--- $file (last lines)"
      tail -n 15 "$file"
    done
  if [[ -s $out/emulator-freeze.txt ]]; then
    # The monitor may still be writing it (gdb): wait for its last line, at most 90 s.
    for _ in $(seq 45); do
      grep -q '^--- end of the freeze dump' "$out/emulator-freeze.txt" && break
      sleep 2
    done
    echo "--- frozen emulator: threads and backtraces (emulator-freeze.txt)"
    head -n "${DIAG_FREEZE_LINES:-700}" "$out/emulator-freeze.txt" | cut -c1-200
  fi
  if [[ -n ${2:-} && -s ${2:-} ]]; then
    guest_log_digest "$2"
  fi
}
# The guest log lines that matter before a loss: our app's process (from ActivityManager's
# « Start proc <pid>:<package> »), crashes, watchdog, audio, media codecs, graphics, low memory;
# then the last lines whatever they are.
guest_log_digest() {
  local file="$1" pids
  pids="$(grep -oE "Start proc [0-9]+:$pkg" "$file" | grep -oE '[0-9]+' | sort -u | paste -sd'|' -)"
  echo "--- guest log digest ($(basename "$file")): our app${pids:+ (pid $pids)}, crashes, watchdog, audio, media, graphics"
  grep -E "${pids:+^[0-9-]+ [0-9:.]+ +($pids) |}$pkg|AndroidRuntime|FATAL|ANR in|[Ww]atchdog|WATCHDOG|am_crash|am_anr|AudioFlinger|AAudio|AudioTrack|audioserver|audio_hw|CCodec|MediaCodec|c2\.goldfish|ExoPlayer|EGL_emulation|gralloc|goldfish|lowmemorykiller|lmkd" "$file" |
    tail -n "${DIAG_DIGEST_LINES:-90}" | cut -c1-240
  echo "--- guest log, last lines before the loss"
  tail -n "${DIAG_LOG_LINES:-25}" "$file" | cut -c1-240
}
annotate() { [[ -n "${GITHUB_ACTIONS:-}" ]] && echo "::$1 title=Emulator API ${api:-?}::$2"; return 0; }
shot() { timeout 30 "$ADB_BIN" exec-out screencap -p >"$out/$1.png" 2>/dev/null || log "screenshot $1 failed"; }
device_ms() { echo $(($(adb shell date +%s | tr -d '\r') * 1000)); }

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
# Optional display override (same layout in dp, fewer pixels for the software renderer).
if [[ -n ${EMULATOR_WM_SIZE:-} ]]; then
  adb shell wm size "$EMULATOR_WM_SIZE" >/dev/null 2>&1 || log "wm size $EMULATOR_WM_SIZE failed"
fi
if [[ -n ${EMULATOR_WM_DENSITY:-} ]]; then
  adb shell wm density "$EMULATOR_WM_DENSITY" >/dev/null 2>&1 || log "wm density $EMULATOR_WM_DENSITY failed"
fi
size="$(adb shell wm size | tr -d '\r' | sed 's/.*: //' | tail -n 1)"
density="$(adb shell wm density | tr -d '\r' | sed 's/.*: //' | tail -n 1)"
log "device $serial: Android $release (API $api), screen $size @ ${density} dpi"
{
  echo "### Emulator: Android $release (API $api), $size, ${density} dpi"
  echo
} >>"$summary"
start_host_monitor

status_a="fail"
status_b="fail"

# ---------------------------------------------------------------------------------------------
# A. Release demo APK
# ---------------------------------------------------------------------------------------------
stage_a() {
  log "A. release demo APK: $release_apk"
  adb uninstall "$pkg" >/dev/null 2>&1 || true
  if ! timeout 300 "$ADB_BIN" install -r "$release_apk" >"$out/a-install.txt" 2>&1; then
    cat "$out/a-install.txt"
    device_alive || host_diagnostics "device lost while installing"
    annotate error "A: the release demo APK does not install"
    echo "| A. Release demo APK (R8) | **FAIL** | does not install |" >>"$out/rows.md"
    return 1
  fi
  grant
  adb logcat -c
  start_logcat_stream "$out/a-logcat-stream.txt"
  local component
  component="$(adb shell cmd package resolve-activity --brief -c android.intent.category.LAUNCHER "$pkg" | tr -d '\r' | tail -n 1)"
  [[ "$component" == */* ]] || component="$pkg/be.cinaf.eventide.MainActivity"
  log "A. launching $component"
  local t0 status
  t0="$(date +%s)"
  timeout "${AM_START_TIMEOUT:-60}" "$ADB_BIN" shell am start -W -n "$component" 2>&1 | tr -d '\r' >"$out/a-am-start.txt"
  cat "$out/a-am-start.txt"
  status="$(sed -n 's/^Status: //p' "$out/a-am-start.txt" | head -n 1)"

  # Wait for the first frame (« Status: ok », or ActivityTaskManager's « Displayed » line after
  # an am start timeout) and the demo-mode line, or a crash, a dead process, a lost device.
  local ready_timeout="${A_READY_TIMEOUT:-120}" displayed="" marker="" pid="" seen_pid=""
  local crashes="" lost="" ready_after=""
  while :; do
    if ! device_alive; then
      lost="yes"
      break
    fi
    timeout 30 "$ADB_BIN" logcat -d -v brief >"$out/a-logcat.txt" 2>/dev/null || true
    pid="$(timeout 20 "$ADB_BIN" shell pidof "$pkg" 2>/dev/null | tr -d '\r')"
    [[ -n $pid ]] && seen_pid="$pid"
    crashes="$(find_crashes "$out/a-logcat.txt")"
    if [[ $status == "ok" ]] || grep -qF "Displayed $pkg/" "$out/a-logcat.txt"; then displayed="yes"; fi
    grep -qF "$demo_marker" "$out/a-logcat.txt" && marker="yes"
    [[ -n $crashes ]] && break
    [[ -n $seen_pid && -z $pid ]] && break
    if [[ -n $displayed && -n $marker && -n $pid ]]; then
      ready_after="$(($(date +%s) - t0))"
      break
    fi
    (($(date +%s) - t0 >= ready_timeout)) && break
    sleep 3
  done

  if [[ -z $lost && -n $ready_after ]]; then
    log "A. first frame drawn and demo mode on after ${ready_after} s; watching the app for ${A_SETTLE:-15} s"
    shot a-1-ready
    sleep "${A_SETTLE:-15}"
    if device_alive; then
      shot a-2-after-settle
      timeout 30 "$ADB_BIN" logcat -d -v brief >"$out/a-logcat.txt" 2>/dev/null || true
      pid="$(timeout 20 "$ADB_BIN" shell pidof "$pkg" 2>/dev/null | tr -d '\r')"
      crashes="$(find_crashes "$out/a-logcat.txt")"
    else
      lost="yes"
    fi
  elif [[ -z $lost ]]; then
    shot a-1-not-ready
  fi
  stop_logcat_stream

  local ok=0 first_frame
  first_frame="$(grep -F "Displayed $pkg/" "$out/a-logcat.txt" 2>/dev/null | head -n 1 | grep -oE '\+([0-9]+s)?[0-9]+ms' | head -n 1)"
  if [[ -n $lost ]]; then
    host_diagnostics "device lost during stage A" "$out/a-logcat-stream.txt"
    annotate error "A: the emulator disconnected $(($(date +%s) - t0)) s after the launch (see host diagnostics in the job log)"
    echo "| A. Release demo APK (R8) | **FAIL** | emulator lost $(($(date +%s) - t0)) s after the launch |" >>"$out/rows.md"
    return 1
  fi
  if [[ $status != "ok" ]]; then
    if [[ ($status == "timeout" || -z $status) && -n $displayed ]]; then
      log "A. am start -W: « Status: ${status:-none} », but the first frame was drawn (${first_frame:-?}): accepted"
    elif [[ -z $status ]]; then
      annotate error "A: am start -W gave no status within ${AM_START_TIMEOUT:-60} s and no first frame was drawn within ${ready_timeout} s: $(grep -m 1 -E 'Error|Exception' "$out/a-am-start.txt")"
      ok=1
    elif [[ $status == "timeout" ]]; then
      annotate error "A: am start -W timed out and the first frame was never drawn within ${ready_timeout} s (no « Displayed $pkg/ » in logcat)"
      ok=1
    else
      annotate error "A: am start -W reported « Status: $status »"
      ok=1
    fi
  fi
  if [[ -z $pid ]]; then
    annotate error "A: the release demo app is not running (crash?)"
    ok=1
  fi
  if [[ -n $crashes ]]; then
    echo "$crashes" | head -n 60
    # Full first stack trace with its causes in the job log (artifacts may not be reachable).
    grep -m 1 -A 60 'FATAL EXCEPTION' "$out/a-logcat.txt" | grep -E 'FATAL|Process:|Exception|Error|Caused by|at ' | head -n 40 || true
    annotate error "A: crash, ANR or Dart error in logcat (see a-logcat.txt): $(echo "$crashes" | head -n 1)"
    ok=1
  fi
  if [[ -z $marker ]]; then
    # Dart's print reaches logcat in release builds too (tag « flutter »): a missing line means
    # that startEventide() did not reach createAppModel() in time, or demo mode is off.
    echo "flutter log lines in logcat: $(grep -c '^[A-Z]/flutter' "$out/a-logcat.txt")"
    grep -E '^[A-Z]/flutter' "$out/a-logcat.txt" | head -n 5
    annotate error "A: « $demo_marker » missing from logcat ${ready_timeout} s after the launch: the release demo build did not enter demo mode (or its startup never got that far)"
    ok=1
  fi
  echo "| A. Release demo APK (R8) | $([[ $ok -eq 0 ]] && echo OK || echo '**FAIL**') | pid ${pid:-none}, am start ${status:-no status}, first frame ${first_frame:-?}, ready after ${ready_after:-?} s |" >>"$out/rows.md"
  adb shell am force-stop "$pkg" || true
  # The debug build of stage B is signed with another key: start from a clean install.
  adb uninstall "$pkg" >/dev/null 2>&1 || true
  return "$ok"
}

# ---------------------------------------------------------------------------------------------
# B. Integration test (flutter drive, debug demo build)
# ---------------------------------------------------------------------------------------------
stage_b() {
  if ! device_alive; then
    log "B. not run: no device"
    annotate error "B: not run, the emulator was lost before the integration test"
    echo "| B. Integration test (debug demo) | **FAIL** | not run: emulator lost before |" >>"$out/rows.md"
    return 1
  fi
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
  start_logcat_stream "$out/b-logcat-stream.txt"
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
  stop_logcat_stream
  if ! device_alive; then
    host_diagnostics "device lost during stage B" "$out/b-logcat-stream.txt"
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
  start_logcat_stream "$out/c-logcat-stream.txt"
  adb shell input keyevent KEYCODE_HOME
  sleep 2
  shot c-1-home
  local now_ms deadline
  now_ms="$(device_ms)"
  deadline=$((at_ms + 100000))
  log "C. app in background; schedule at $at_ms, device now $now_ms (in $(((at_ms - now_ms) / 1000)) s)"
  local seen=""
  while device_alive && (($(device_ms) < deadline)); do
    adb logcat -d -v brief >"$out/c-logcat.txt"
    if grep -Eq 'EventideSchedule.*(playback started for schedule|nothing played for schedule|fallback|no-connection|skipped|nothing to start)' "$out/c-logcat.txt"; then
      seen="yes"
      sleep 8 # let the service and the notification settle
      break
    fi
    sleep 5
  done
  stop_logcat_stream
  if ! device_alive; then
    host_diagnostics "device lost during stage C" "$out/c-logcat-stream.txt"
    echo "the emulator was lost while waiting for the scheduled start" | tee -a "$result"
    echo fail >"$out/scheduled-start.status"
    echo "| C. Scheduled start (background) | **FAIL** | emulator lost |" >>"$out/rows.md"
    return 0
  fi
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
