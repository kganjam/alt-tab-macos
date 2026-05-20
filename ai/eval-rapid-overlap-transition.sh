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

SOURCE_APP=${SOURCE_APP:-Safari}
FIRST_APP=${FIRST_APP:-OneNote}
SECOND_APP=${SECOND_APP:-Terminal}
SOURCE_WID=${SOURCE_WID:-}
FIRST_WID=${FIRST_WID:-}
SECOND_WID=${SECOND_WID:-}
SOURCE_INDEX=${SOURCE_INDEX:-0}
FIRST_INDEX=${FIRST_INDEX:-0}
SECOND_INDEX=${SECOND_INDEX:-0}
SETTLE_MS=${SETTLE_MS:-900}
GAP_MS=${GAP_MS:-260}
SHOW_TO_SELECT_MS=${SHOW_TO_SELECT_MS:-80}
SELECT_TO_FOCUS_MS=${SELECT_TO_FOCUS_MS:-45}
DURATION_MS=${DURATION_MS:-4200}
INTERVAL_MS=${INTERVAL_MS:-8}
SHIFT_PROBE=${SHIFT_PROBE:-1}
ATOMIC_SELECT_FOCUS=${ATOMIC_SELECT_FOCUS:-1}
WAIT_SOURCE_MS=${WAIT_SOURCE_MS:-3500}
SOURCE_CHECK_INTERVAL_MS=${SOURCE_CHECK_INTERVAL_MS:-100}
PROBE_DELAY_MS=${PROBE_DELAY_MS:-350}
SAMPLER=${SAMPLER:-/tmp/alttab-z-order-sampler}
PROBER=${PROBER:-/tmp/alttab-post-shift-probe}
MARKER=${MARKER:-rapid-overlap-$(date +%Y%m%d-%H%M%S)-$$}
OUT=${OUT:-/tmp/alttab-rapid-overlap-${MARKER}.jsonl}
LOG_SCAN=${LOG_SCAN:-/tmp/alttab-rapid-overlap-${MARKER}.logscan.txt}
Z_SCAN=${Z_SCAN:-/tmp/alttab-rapid-overlap-${MARKER}.zscan.txt}
if [ -d "$OUT" ]; then
  OUT="$OUT/zsamples.jsonl"
fi

bash ai/eval-user-idle-guard.sh "rapid-$SOURCE_APP-to-$FIRST_APP-to-$SECOND_APP"

popup_guard() {
  MARKER="$MARKER" POPUP_STORM_CONTEXT="$1" bash ai/eval-popup-storm-guard.sh
}
popup_guard "rapid-preflight-$SOURCE_APP-$FIRST_APP-$SECOND_APP"

if [ ! -x "$SAMPLER" ] || [ ai/z-order-sampler.swift -nt "$SAMPLER" ]; then
  swiftc ai/z-order-sampler.swift -o "$SAMPLER"
fi
if [ "$SHIFT_PROBE" = "1" ] && { [ ! -x "$PROBER" ] || [ ai/post-shift-probe.swift -nt "$PROBER" ]; }; then
  swiftc ai/post-shift-probe.swift -o "$PROBER"
fi

pick_window() {
  local app=$1 index=$2
  alttab --detailed-list | jq -c --arg app "$app" --argjson index "$index" '[.windows[] | select((.appName | test($app; "i")) and (.isMinimized | not))][$index]'
}
window_by_id_or_pattern() {
  local wid=$1 app=$2 index=$3
  if [ -n "$wid" ]; then
    alttab --detailed-list | jq -c --argjson wid "$wid" 'first(.windows[] | select(.id == $wid))'
  else
    pick_window "$app" "$index"
  fi
}
sleep_ms() { python3 - "$1" <<'PY'
import sys, time
time.sleep(int(sys.argv[1]) / 1000)
PY
}

wait_for_source_ready() {
  local max_ms=$1
  local interval_ms=$2
  local attempts=$(( (max_ms + interval_ms - 1) / interval_ms ))
  local sample ready elapsed
  for ((i = 0; i <= attempts; i++)); do
    sample=$("$SAMPLER" --target-wid "$source_wid" --target-pid "$source_pid" --duration-ms 1 --interval-ms 1 | tail -1)
    ready=$(jq -r '.target_z == 0 and (.front_pid == .target_pid or .target_pid == 0)' <<<"$sample")
    if [ "$ready" = "true" ]; then
      elapsed=$(( i * interval_ms ))
      echo "source_ready_ms=$elapsed source_wid=$source_wid source_pid=$source_pid" >&2
      return 0
    fi
    sleep_ms "$interval_ms"
  done
  echo "source_not_ready_after_ms=$max_ms source_wid=$source_wid source_pid=$source_pid last_sample=$sample" >&2
  return 1
}

source_json=$(window_by_id_or_pattern "$SOURCE_WID" "$SOURCE_APP" "$SOURCE_INDEX")
first_json=$(window_by_id_or_pattern "$FIRST_WID" "$FIRST_APP" "$FIRST_INDEX")
second_json=$(window_by_id_or_pattern "$SECOND_WID" "$SECOND_APP" "$SECOND_INDEX")
for item in source_json first_json second_json; do
  value=${!item}
  if [ -z "$value" ] || [ "$value" = "null" ]; then
    echo "Missing window for $item" >&2
    exit 2
  fi
done
source_wid=$(jq -r '.id' <<<"$source_json")
source_pid=$(jq -r '.pid // 0' <<<"$source_json")
first_wid=$(jq -r '.id' <<<"$first_json")
second_wid=$(jq -r '.id' <<<"$second_json")
second_pid=$(jq -r '.pid // 0' <<<"$second_json")
source_label=$(jq -r '.appName + ":" + (.title // "")' <<<"$source_json")
first_label=$(jq -r '.appName + ":" + (.title // "")' <<<"$first_json")
second_label=$(jq -r '.appName + ":" + (.title // "")' <<<"$second_json")

printf '=== EVAL MARKER: %s ===\n' "$MARKER" >> /tmp/alttab-run.log
popup_guard "rapid-before-source-focus-$SOURCE_APP"
alttab --focus="$source_wid" >/dev/null
sleep_ms "$SETTLE_MS"
if ! wait_for_source_ready "$WAIT_SOURCE_MS" "$SOURCE_CHECK_INTERVAL_MS"; then
  printf '=== EVAL END MARKER: %s ===\n' "$MARKER" >> /tmp/alttab-run.log
  exit 4
fi
popup_guard "rapid-before-sampler"
"$SAMPLER" --target-wid "$second_wid" --target-pid "$second_pid" --duration-ms "$DURATION_MS" --interval-ms "$INTERVAL_MS" > "$OUT" &
sampler_pid=$!
sleep_ms 160

focus_target_via_panel() {
  local wid=$1
  alttab --show=0 >/dev/null
  sleep_ms "$SHOW_TO_SELECT_MS"
  local state selected
  if [ "$ATOMIC_SELECT_FOCUS" = "1" ]; then
    state=$(alttab --select-and-focus="$wid")
  else
    alttab --select="$wid" >/dev/null
    state=$(alttab --selection-state)
  fi
  selected=$(jq -r '.selectedWindow.id // 0' <<<"$state")
  if [ "$selected" != "$wid" ]; then
    echo "selection mismatch: wanted=$wid selected=$selected" >&2
    return 3
  fi
  if [ "$ATOMIC_SELECT_FOCUS" != "1" ]; then
    sleep_ms "$SELECT_TO_FOCUS_MS"
    alttab --focus-target >/dev/null
  fi
}

focus_target_via_panel "$first_wid"
sleep_ms "$GAP_MS"
focus_target_via_panel "$second_wid"
if [ "$SHIFT_PROBE" = "1" ]; then
  sleep_ms "$PROBE_DELAY_MS"
  "$PROBER" >/dev/null
fi
wait "$sampler_pid"
popup_guard "rapid-after-sampler"
printf '=== EVAL END MARKER: %s ===\n' "$MARKER" >> /tmp/alttab-run.log
final_front=$(osascript -e 'tell application "System Events" to get name of first application process whose frontmost is true' 2>/dev/null || true)

set +e
python3 - "$OUT" "$second_wid" "$source_wid" "$first_wid" "$second_pid" "$source_label" "$first_label" "$second_label" "$GAP_MS" "$final_front" > "$Z_SCAN" <<'PY'
import json, sys
path, second_wid, source_wid, first_wid, second_pid = sys.argv[1], int(sys.argv[2]), int(sys.argv[3]), int(sys.argv[4]), int(sys.argv[5])
source_label, first_label, second_label, gap_ms, final_front = sys.argv[6:11]
second_app = second_label.split(':', 1)[0]
rows=[]
with open(path) as f:
    for line in f:
        try: rows.append(json.loads(line))
        except Exception: pass
first_z0 = next((r['t_ms'] for r in rows if r.get('target_z') == 0), None)
post = [r for r in rows if first_z0 is not None and r['t_ms'] >= first_z0]
flickers = [r for r in post if r.get('target_z') != 0]
source_after = [r for r in post if r.get('top_wid') == source_wid]
first_after = [r for r in post if r.get('top_wid') == first_wid]
final = rows[-1] if rows else {}
changes=[]; last=None
for r in rows:
    cur=(r.get('top_wid'), r.get('top_owner'), r.get('target_z'))
    if cur != last:
        changes.append((round(r['t_ms'], 1), cur)); last=cur
print(f"rapid-overlap gap_ms={gap_ms} source={source_label[:80]!r} first={first_label[:80]!r} second={second_label[:80]!r} final_front={final_front!r}")
print(f"samples={len(rows)} file={path}")
print(f"first_second_z0_ms={first_z0 if first_z0 is not None else 'never'} final_top={(final.get('top_wid'), final.get('top_owner'), final.get('target_z'))}")
print(f"final_front_pid={final.get('front_pid')} final_ns_front_pid={final.get('ns_front_pid')} expected_pid={second_pid}")
print(f"flicker_after_z0_samples={len(flickers)} source_reappears_after_z0_samples={len(source_after)} first_target_reappears_after_z0_samples={len(first_after)}")
print("top_changes_ms=(top_wid,top_owner,target_z)")
for t, cur in changes[:30]: print(f"  {t} {cur}")
if len(changes) > 30: print(f"  ... {len(changes)-30} more")
front_pid_ok = final.get('front_pid') == second_pid
front_name_ok = bool(final_front) and (final_front.lower() in second_app.lower() or second_app.lower() in final_front.lower())
front_ok = front_pid_ok or front_name_ok
failed = first_z0 is None or final.get('top_wid') != second_wid or not front_ok or flickers or source_after or first_after
sys.exit(1 if failed else 0)
PY
z_status=$?
cat "$Z_SCAN"
python3 ai/eval-log-anomalies.py --marker "$MARKER" --end-marker "=== EVAL END MARKER: $MARKER ===" --expected-final-wid "$second_wid" --check-stale-events --fail-mouse-events --strict > "$LOG_SCAN"
log_status=$?
set -e
cat "$LOG_SCAN"
if [ "$z_status" -ne 0 ] || [ "$log_status" -ne 0 ]; then
  exit 1
fi
