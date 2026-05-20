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
SOURCE_APP=${1:-Terminal}
TARGET_APP=${2:-Safari}
SOURCE_WID=${SOURCE_WID:-}
TARGET_WID=${TARGET_WID:-}
SOURCE_INDEX=${SOURCE_INDEX:-0}
TARGET_INDEX=${TARGET_INDEX:-0}
DURATION_MS=${DURATION_MS:-2600}
INTERVAL_MS=${INTERVAL_MS:-5}
PRE_MS=${PRE_MS:-250}
SETTLE_MS=${SETTLE_MS:-700}
SHOW_TO_SELECT_MS=${SHOW_TO_SELECT_MS:-80}
SELECT_TO_FOCUS_MS=${SELECT_TO_FOCUS_MS:-45}
SHIFT_PROBE=${SHIFT_PROBE:-0}
ATOMIC_SELECT_FOCUS=${ATOMIC_SELECT_FOCUS:-1}
MAX_Z0_MS=${MAX_Z0_MS:-1000}
WAIT_SOURCE_MS=${WAIT_SOURCE_MS:-3500}
SOURCE_CHECK_INTERVAL_MS=${SOURCE_CHECK_INTERVAL_MS:-100}
SOURCE_STABLE_SAMPLES=${SOURCE_STABLE_SAMPLES:-3}
PROBE_DELAY_MS=${PROBE_DELAY_MS:-250}
SAMPLER=${SAMPLER:-/tmp/alttab-z-order-sampler}
SAMPLER_FLAGS=${SAMPLER_FLAGS:-}
PROBER=${PROBER:-/tmp/alttab-post-shift-probe}
OUT=${OUT:-/tmp/alttab-select-zorder-$(date +%Y%m%d-%H%M%S).jsonl}
MARKER=${MARKER:-select-transition-$(date +%Y%m%d-%H%M%S)-$$}
LOG_SCAN=${LOG_SCAN:-/tmp/alttab-select-${MARKER}.logscan.txt}
Z_SCAN=${Z_SCAN:-/tmp/alttab-select-${MARKER}.zscan.txt}
if [ -d "$OUT" ]; then
  OUT="$OUT/zsamples.jsonl"
fi

bash ai/eval-user-idle-guard.sh "select-$SOURCE_APP-to-$TARGET_APP"

popup_guard() {
  MARKER="$MARKER" POPUP_STORM_CONTEXT="$1" bash ai/eval-popup-storm-guard.sh
}
popup_guard "select-preflight-$SOURCE_APP-to-$TARGET_APP"

if [ ! -x "$SAMPLER" ] || [ ai/z-order-sampler.swift -nt "$SAMPLER" ]; then
  swiftc ai/z-order-sampler.swift -o "$SAMPLER"
fi
if [ "$SHIFT_PROBE" = "1" ] && { [ ! -x "$PROBER" ] || [ ai/post-shift-probe.swift -nt "$PROBER" ]; }; then
  swiftc ai/post-shift-probe.swift -o "$PROBER"
fi

pick_window() {
  local app=$1
  local index=$2
  alttab --detailed-list | jq -c --arg app "$app" --argjson index "$index" '[.windows[] | select((.appName | test($app; "i")) and (.isMinimized | not) and (.isDisplayable // true))][$index]'
}

sleep_ms() {
  python3 - "$1" <<'PY'
import sys
print(int(sys.argv[1]) / 1000)
PY
}

wait_for_source_ready() {
  local max_ms=$1
  local interval_ms=$2
  local attempts=$(( (max_ms + interval_ms - 1) / interval_ms ))
  local sample ready elapsed stable=0
  for ((i = 0; i <= attempts; i++)); do
    if [ -n "$SAMPLER_FLAGS" ]; then
      sample=$("$SAMPLER" --target-wid "$source_wid" --target-pid "$source_pid" --duration-ms 1 --interval-ms 1 $SAMPLER_FLAGS | tail -1)
    else
      sample=$("$SAMPLER" --target-wid "$source_wid" --target-pid "$source_pid" --duration-ms 1 --interval-ms 1 | tail -1)
    fi
    ready=$(jq -r '.target_z == 0 and (.front_pid == .target_pid or .target_pid == 0)' <<<"$sample")
    if [ "$ready" = "true" ]; then
      stable=$(( stable + 1 ))
      if [ "$stable" -ge "$SOURCE_STABLE_SAMPLES" ]; then
        elapsed=$(( i * interval_ms ))
        echo "source_ready_ms=$elapsed stable_samples=$stable source_wid=$source_wid source_pid=$source_pid" >&2
        return 0
      fi
    else
      stable=0
    fi
    sleep "$(sleep_ms "$interval_ms")"
  done
  echo "source_not_ready_after_ms=$max_ms source_wid=$source_wid source_pid=$source_pid last_sample=$sample" >&2
  return 1
}

if [ -n "$SOURCE_WID" ]; then
  source_json=$(alttab --detailed-list | jq -c --argjson wid "$SOURCE_WID" 'first(.windows[] | select(.id == $wid))')
else
  source_json=$(pick_window "$SOURCE_APP" "$SOURCE_INDEX")
fi
if [ -n "$TARGET_WID" ]; then
  target_json=$(alttab --detailed-list | jq -c --argjson wid "$TARGET_WID" 'first(.windows[] | select(.id == $wid))')
else
  target_json=$(pick_window "$TARGET_APP" "$TARGET_INDEX")
fi
if [ -z "$source_json" ] || [ "$source_json" = "null" ]; then
  echo "No source window matching app pattern: $SOURCE_APP" >&2
  exit 2
fi
if [ -z "$target_json" ] || [ "$target_json" = "null" ]; then
  echo "No target window matching app pattern: $TARGET_APP" >&2
  exit 2
fi

source_wid=$(jq -r '.id' <<<"$source_json")
source_pid=$(jq -r '.pid // 0' <<<"$source_json")
target_wid=$(jq -r '.id' <<<"$target_json")
target_pid=$(jq -r '.pid // 0' <<<"$target_json")
source_title=$(jq -r '.title // ""' <<<"$source_json")
target_title=$(jq -r '.title // ""' <<<"$target_json")

printf '=== EVAL MARKER: %s ===\n' "$MARKER" >> /tmp/alttab-run.log
popup_guard "select-before-source-focus-$SOURCE_APP-to-$TARGET_APP"
alttab --focus="$source_wid" >/dev/null
sleep "$(sleep_ms "$SETTLE_MS")"
if ! wait_for_source_ready "$WAIT_SOURCE_MS" "$SOURCE_CHECK_INTERVAL_MS"; then
  printf '=== EVAL END MARKER: %s ===\n' "$MARKER" >> /tmp/alttab-run.log
  exit 4
fi
alttab --selection-state 2>/dev/null | jq -e --argjson wid "$target_wid" 'any(.windows[]; .id == $wid)' >/dev/null
if ! wait_for_source_ready "$WAIT_SOURCE_MS" "$SOURCE_CHECK_INTERVAL_MS"; then
  printf '=== EVAL END MARKER: %s ===\n' "$MARKER" >> /tmp/alttab-run.log
  exit 4
fi
popup_guard "select-before-sampler-$SOURCE_APP-to-$TARGET_APP"

if [ -n "$SAMPLER_FLAGS" ]; then
  "$SAMPLER" --target-wid "$target_wid" --target-pid "$target_pid" --duration-ms "$DURATION_MS" --interval-ms "$INTERVAL_MS" $SAMPLER_FLAGS > "$OUT" &
else
  "$SAMPLER" --target-wid "$target_wid" --target-pid "$target_pid" --duration-ms "$DURATION_MS" --interval-ms "$INTERVAL_MS" > "$OUT" &
fi
sampler_pid=$!
sleep "$(sleep_ms "$PRE_MS")"
alttab --show=0 >/dev/null
sleep "$(sleep_ms "$SHOW_TO_SELECT_MS")"
if [ "$ATOMIC_SELECT_FOCUS" = "1" ]; then
  state_after_select=$(alttab --select-and-focus="$target_wid")
else
  alttab --select="$target_wid" >/dev/null
  state_after_select=$(alttab --selection-state 2>/dev/null)
fi
selected_wid=$(jq -r '.selectedWindow.id // 0' <<<"$state_after_select")
selected_app=$(jq -r '.selectedWindow.appName // ""' <<<"$state_after_select")
selected_index=$(jq -r '.selectedIndex // -1' <<<"$state_after_select")
if [ "$ATOMIC_SELECT_FOCUS" != "1" ]; then
  sleep "$(sleep_ms "$SELECT_TO_FOCUS_MS")"
  alttab --focus-target >/dev/null
fi
if [ "$SHIFT_PROBE" = "1" ]; then
  sleep "$(sleep_ms "$PROBE_DELAY_MS")"
  "$PROBER" >/dev/null
fi
wait "$sampler_pid"
popup_guard "select-after-sampler-$SOURCE_APP-to-$TARGET_APP"
printf '=== EVAL END MARKER: %s ===\n' "$MARKER" >> /tmp/alttab-run.log
final_front=$(osascript -e 'tell application "System Events" to get name of first application process whose frontmost is true' 2>/dev/null || true)

set +e
python3 - "$OUT" "$PRE_MS" "$source_wid" "$target_wid" "$target_pid" "$SOURCE_APP" "$TARGET_APP" "$source_title" "$target_title" "$final_front" "$selected_index" "$selected_wid" "$selected_app" "$SHOW_TO_SELECT_MS" "$SELECT_TO_FOCUS_MS" "$SHIFT_PROBE" "$MAX_Z0_MS" > "$Z_SCAN" <<'PY'
import json, sys
path, pre_ms, source_wid, target_wid, target_pid = sys.argv[1], float(sys.argv[2]), int(sys.argv[3]), int(sys.argv[4]), int(sys.argv[5])
source_app, target_app, source_title, target_title, final_front = sys.argv[6:11]
selected_index, selected_wid, selected_app, show_to_select_ms, select_to_focus_ms, shift_probe = sys.argv[11], int(sys.argv[12]), sys.argv[13], sys.argv[14], sys.argv[15], sys.argv[16]
max_z0_ms = float(sys.argv[17])
rows = []
with open(path) as f:
    for line in f:
        try:
            rows.append(json.loads(line))
        except json.JSONDecodeError:
            pass
after = [r for r in rows if r["t_ms"] >= pre_ms]
before = [r for r in rows if r["t_ms"] < pre_ms]
baseline = before[-1] if before else {}
first_z0 = next((r["t_ms"] - pre_ms for r in after if r.get("target_z") == 0), None)
post_z0 = [r for r in after if first_z0 is not None and r["t_ms"] - pre_ms >= first_z0]
flickers = [r for r in post_z0 if r.get("target_z") != 0]
source_after_z0 = [r for r in post_z0 if r.get("top_wid") == source_wid]
missing = sum(1 for r in after if r.get("target_z") is None)
same_above_max = max((r.get("same_app_above") or 0 for r in after), default=0)
same_above_after_z0 = max((r.get("same_app_above") or 0 for r in post_z0), default=0)
pre_top = list(zip(baseline.get("top_wids", []), baseline.get("top_pids", []), baseline.get("top_owners", [])))
pre_rank = {int(w): i for i, (w, _, _) in enumerate(pre_top)}
divider = next(((int(w), int(p), o, i) for i, (w, p, o) in enumerate(pre_top) if int(w) not in (source_wid, target_wid) and int(p) != target_pid), None)
def sibling_intrusions(row):
    if not divider:
        return []
    divider_wid, _, _, divider_pre_rank = divider
    top = list(zip(row.get("top_wids", []), row.get("top_pids", []), row.get("top_owners", [])))
    actual_rank = {int(w): i for i, (w, _, _) in enumerate(top)}
    divider_actual_rank = actual_rank.get(divider_wid)
    if divider_actual_rank is None:
        return []
    bad = []
    for i, (w, p, _) in enumerate(top):
        w, p = int(w), int(p)
        if w == target_wid or p != target_pid or i >= divider_actual_rank:
            continue
        if pre_rank.get(w, 10**9) > divider_pre_rank:
            bad.append(w)
    return bad
sibling_rows = [(r, sibling_intrusions(r)) for r in post_z0]
sibling_intrusion_max = max((len(wids) for _, wids in sibling_rows), default=0)
sibling_intrusion_first = next(((r["t_ms"] - pre_ms, wids) for r, wids in sibling_rows if wids), None)
final_row = after[-1] if after else (rows[-1] if rows else {})
final_top8 = list(zip(final_row.get("top_wids", []), final_row.get("top_owners", [])))[:8]
top_changes = []
last = None
for r in after:
    cur = (r.get("top_wid"), r.get("top_owner"), r.get("target_z"), r.get("same_app_above"))
    if cur != last:
        top_changes.append((round(r["t_ms"] - pre_ms, 1), cur))
        last = cur
print(f"select-switch {source_app!r}->{target_app!r} source_wid={source_wid} target_wid={target_wid} show_to_select_ms={show_to_select_ms} select_to_focus_ms={select_to_focus_ms}")
print(f"source_title={source_title[:80]!r}")
print(f"target_title={target_title[:80]!r}")
print(f"selected_index_after_select={selected_index} selected=({selected_wid},{selected_app!r}) final_front={final_front!r} shift_probe={shift_probe}")
print(f"samples={len(rows)} after_switch={len(after)} file={path}")
print(f"pre_top8={[(w, o) for w, _, o in pre_top[:8]]}")
print(f"final_top8={final_top8}")
print(f"first_target_z0_ms={first_z0 if first_z0 is not None else 'never'}")
print(f"max_z0_ms={max_z0_ms}")
print(f"flicker_after_z0_samples={len(flickers)} source_reappears_after_z0_samples={len(source_after_z0)} target_missing_samples={missing}")
print(f"same_app_above_max={same_above_max} same_app_above_after_z0_max={same_above_after_z0}")
print(f"sibling_intrusions_after_z0_max={sibling_intrusion_max} first={sibling_intrusion_first if sibling_intrusion_first else 'none'}")
ns_front_pid = final_row.get("ns_front_pid")
ax_front_pid = final_row.get("ax_front_pid")
carbon_front_pid = final_row.get("carbon_front_pid")
ax_focused_wid = final_row.get("ax_focused_wid")
print(f"final_front_pid={final_row.get('front_pid')} final_ax_front_pid={ax_front_pid} final_carbon_front_pid={carbon_front_pid} final_ns_front_pid={ns_front_pid} final_ax_focused_wid={ax_focused_wid} expected_pid={target_pid}")
print("app_top_changes_ms=(top_wid,top_owner,target_z,same_app_above)")
for item in top_changes[:24]:
    print(f"  {item[0]} {item[1]}")
if len(top_changes) > 24:
    print(f"  ... {len(top_changes) - 24} more")
front_pid_ok = target_pid in (final_row.get("front_pid"), ax_front_pid, carbon_front_pid)
ns_front_ok = ns_front_pid in (target_pid, 0, None)
ax_window_ok = ax_focused_wid in (target_wid, None)
front_name_ok = bool(final_front) and (final_front.lower() in target_app.lower() or target_app.lower() in final_front.lower())
front_ok = front_pid_ok or front_name_ok
if not ns_front_ok:
    print(f"front_signal_warning=ns_front_pid:{ns_front_pid} expected:{target_pid} (informational; sampler NSWorkspace can be stale without a runloop)")
if not ax_window_ok:
    print(f"front_signal_mismatch=ax_focused_wid:{ax_focused_wid} expected:{target_wid}")
failed = selected_wid != target_wid or first_z0 is None or first_z0 > max_z0_ms or final_row.get("top_wid") != target_wid or not front_ok or not ax_window_ok or len(flickers) > 0 or sibling_intrusion_max > 0
sys.exit(1 if failed else 0)
PY
z_status=$?
cat "$Z_SCAN"
python3 ai/eval-log-anomalies.py --marker "$MARKER" --end-marker "=== EVAL END MARKER: $MARKER ===" --expected-final-wid "$target_wid" --check-stale-events --fail-mouse-events --strict > "$LOG_SCAN"
log_status=$?
cat "$LOG_SCAN"
set -e
if [ "$z_status" -ne 0 ] || [ "$log_status" -ne 0 ]; then
  exit 1
fi
