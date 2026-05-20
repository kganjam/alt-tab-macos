#!/usr/bin/env bash
set -euo pipefail

APP=${ALTTAB_APP:-/Applications/AltTab.app/Contents/MacOS/AltTab}
if [ -z "${ALTTAB_DYLIB_OVERRIDE:-}" ] && [ -f "$(pwd)/dev/AltTabCore.dylib" ]; then
  export ALTTAB_DYLIB_OVERRIDE="$(pwd)/dev/AltTabCore.dylib"
fi

alttab() {
  local out status
  set +e
  out=$("$APP" "$@" 2>&1)
  status=$?
  set -e
  printf '%s\n' "$out" | sed -n '/^[[:space:]]*[{[]/,$p'
  return "$status"
}

MARKER=${MARKER:-focus-suite-$(date +%Y%m%d-%H%M%S)-$$}
REPS=${REPS:-3}
SHIFT_PROBE=${SHIFT_PROBE:-1}
REQUIRE_PAR=${REQUIRE_PAR:-0}
RUN_COPY=${RUN_COPY:-1}
RUN_RAPID=${RUN_RAPID:-1}
RUN_EXTERNAL=${RUN_EXTERNAL:-1}
OUT_DIR=${OUT_DIR:-/tmp/alttab-focus-suite-$MARKER}
mkdir -p "$OUT_DIR"
bash ai/eval-user-idle-guard.sh "focus-regression-suite"
printf '=== EVAL MARKER: %s ===\n' "$MARKER" >> /tmp/alttab-run.log
EXIT_CODE=0

popup_guard() {
  MARKER="$MARKER" POPUP_STORM_CONTEXT="$1" bash ai/eval-popup-storm-guard.sh
}

abort_on_popup_guard() {
  local status
  popup_guard "$1" && return 0
  status=$?
  printf '=== EVAL END MARKER: %s ===\n' "$MARKER" >> /tmp/alttab-run.log
  echo "ABORT popup storm context=$1 status=$status" | tee -a "$OUT_DIR/summary.txt"
  exit 86
}

has_window() {
  local app=$1
  alttab --detailed-list | jq -e --arg app "$app" 'any(.windows[]; (.appName | test($app; "i")) and (.isMinimized | not) and (.isDisplayable // true))' >/dev/null
}
has_parallels_app() {
  local app=$1
  find "$HOME/Applications (Parallels)" -maxdepth 4 -name "${app}*.app" -print -quit 2>/dev/null | grep -q .
}
run_reps() {
  local name=$1; shift
  local safe=${name//[^A-Za-z0-9_.-]/_}
  for i in $(seq 1 "$REPS"); do
    abort_on_popup_guard "$name-pre-$i"
    echo "===== $name rep $i/$REPS =====" | tee -a "$OUT_DIR/summary.txt"
    set +e
    env MARKER="$MARKER-$safe-$i" OUT="$OUT_DIR/$safe-$i.jsonl" LOG_SCAN="$OUT_DIR/$safe-$i.logscan.txt" Z_SCAN="$OUT_DIR/$safe-$i.zscan.txt" "$@" 2>&1 | tee "$OUT_DIR/$safe-$i.txt"
    local status=${PIPESTATUS[0]}
    set -e
    if [ "$status" -eq 86 ]; then
      printf '=== EVAL END MARKER: %s ===\n' "$MARKER" >> /tmp/alttab-run.log
      echo "ABORT popup storm context=$name rep=$i" | tee -a "$OUT_DIR/summary.txt"
      exit 86
    fi
    abort_on_popup_guard "$name-post-$i"
    if [ "$status" -ne 0 ]; then
      EXIT_CODE=1
      echo "FAIL $name rep $i status=$status" | tee -a "$OUT_DIR/summary.txt"
    fi
  done
}

export SHIFT_PROBE
export DURATION_MS=${DURATION_MS:-3000}
export INTERVAL_MS=${INTERVAL_MS:-6}
export SETTLE_MS=${SETTLE_MS:-900}
export SHOW_TO_SELECT_MS=${SHOW_TO_SELECT_MS:-80}
export SELECT_TO_FOCUS_MS=${SELECT_TO_FOCUS_MS:-45}

abort_on_popup_guard suite-preflight
run_reps terminal_to_safari bash ai/eval-select-transition.sh Terminal Safari
run_reps safari_to_terminal bash ai/eval-select-transition.sh Safari Terminal

if has_window OneNote; then
  export SETTLE_MS=${PAR_SETTLE_MS:-1100}
  export DURATION_MS=${PAR_DURATION_MS:-3600}
  export INTERVAL_MS=${PAR_INTERVAL_MS:-8}
  run_reps onenote_to_safari bash ai/eval-select-transition.sh OneNote Safari
  run_reps safari_to_onenote bash ai/eval-select-transition.sh Safari OneNote
else
  echo "SKIP OneNote/Parallels checks: no OneNote window" | tee -a "$OUT_DIR/summary.txt"
  if [ "$REQUIRE_PAR" = "1" ]; then exit 2; fi
fi

if has_window "Parallels Desktop"; then
  export SETTLE_MS=${PAR_DESKTOP_SETTLE_MS:-1100}
  export DURATION_MS=${PAR_DESKTOP_DURATION_MS:-3600}
  export INTERVAL_MS=${PAR_DESKTOP_INTERVAL_MS:-8}
  run_reps parallels_desktop_to_terminal bash ai/eval-select-transition.sh "Parallels Desktop" Terminal
  run_reps terminal_to_parallels_desktop bash ai/eval-select-transition.sh Terminal "Parallels Desktop"
else
  echo "SKIP Parallels Desktop checks: no displayable Parallels Desktop window" | tee -a "$OUT_DIR/summary.txt"
fi

if [ "$RUN_COPY" = "1" ]; then
  run_reps safari_copy env DELAY=1.2 bash ai/eval-copy-after-focus.sh Safari
fi

if [ "$RUN_RAPID" = "1" ] && has_window OneNote; then
  run_reps rapid_overlap env SOURCE_APP=Safari FIRST_APP=OneNote SECOND_APP=Terminal GAP_MS=260 SHIFT_PROBE=1 bash ai/eval-rapid-overlap-transition.sh
fi

if [ "$RUN_EXTERNAL" = "1" ] && [ -x /Users/kganjam/bin/focus-parallels-outlook ]; then
  run_reps external_outlook_open env SOURCE_APP=Terminal TARGET_OWNER="Outlook (classic)" LAUNCH_COMMAND="/Users/kganjam/bin/focus-parallels-outlook" SIMULATE_EXTERNAL_KEY=1 FAIL_KEY_EVENTS=0 MAX_TO_FRONT_MS=1800 bash ai/eval-external-launch-transition.sh
fi

printf '=== EVAL END MARKER: %s ===\n' "$MARKER" >> /tmp/alttab-run.log
set +e
python3 ai/eval-log-anomalies.py --marker "$MARKER" --end-marker "=== EVAL END MARKER: $MARKER ===" --strict > "$OUT_DIR/log-anomalies.txt"
log_status=$?
set -e
cat "$OUT_DIR/log-anomalies.txt"
if [ "$log_status" -ne 0 ]; then EXIT_CODE=1; fi
prompt=$(OUT="$OUT_DIR/llm-review.md" bash ai/eval-prompt-review.sh "$MARKER" "$OUT_DIR"/*.txt)
echo "LLM review prompt: $prompt"
echo "Suite artifacts: $OUT_DIR"
exit "$EXIT_CODE"
