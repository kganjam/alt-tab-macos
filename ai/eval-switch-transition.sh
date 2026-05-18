#!/usr/bin/env bash
set -euo pipefail

APP=${ALTTAB_APP:-/Applications/AltTab.app/Contents/MacOS/AltTab}
if [ -z "${ALTTAB_DYLIB_OVERRIDE:-}" ] && [ -f "$(pwd)/dev/AltTabCore.dylib" ]; then
  export ALTTAB_DYLIB_OVERRIDE="$(pwd)/dev/AltTabCore.dylib"
fi
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
SHOW_TO_FOCUS_MS=${SHOW_TO_FOCUS_MS:-45}
PREFLIGHT_SHOW_MS=${PREFLIGHT_SHOW_MS:-80}
SHIFT_PROBE=${SHIFT_PROBE:-0}
PROBE_DELAY_MS=${PROBE_DELAY_MS:-250}
SAMPLER=${SAMPLER:-/tmp/alttab-z-order-sampler}
PROBER=${PROBER:-/tmp/alttab-post-shift-probe}
OUT=${OUT:-/tmp/alttab-switch-zorder-$(date +%Y%m%d-%H%M%S).jsonl}

if [ ! -x "$SAMPLER" ] || [ ai/z-order-sampler.swift -nt "$SAMPLER" ]; then
  swiftc ai/z-order-sampler.swift -o "$SAMPLER"
fi
if [ "$SHIFT_PROBE" = "1" ] && { [ ! -x "$PROBER" ] || [ ai/post-shift-probe.swift -nt "$PROBER" ]; }; then
  swiftc ai/post-shift-probe.swift -o "$PROBER"
fi

pick_window() {
  local app=$1
  local index=$2
  "$APP" --detailed-list | jq -c --arg app "$app" --argjson index "$index" '[.windows[] | select((.appName | test($app; "i")) and (.isMinimized | not))][$index]'
}

sleep_ms() {
  python3 - "$1" <<'PY'
import sys
print(int(sys.argv[1]) / 1000)
PY
}

selection_state_after_show() {
  "$APP" --show=0 >/dev/null
  sleep "$(sleep_ms "$PREFLIGHT_SHOW_MS")"
  local state
  state=$("$APP" --selection-state)
  "$APP" --hide >/dev/null || true
  printf '%s\n' "$state"
}

if [ -n "$SOURCE_WID" ]; then
  source_json=$("$APP" --detailed-list | jq -c --argjson wid "$SOURCE_WID" 'first(.windows[] | select(.id == $wid))')
else
  source_json=$(pick_window "$SOURCE_APP" "$SOURCE_INDEX")
fi
if [ -n "$TARGET_WID" ]; then
  target_json=$("$APP" --detailed-list | jq -c --argjson wid "$TARGET_WID" 'first(.windows[] | select(.id == $wid))')
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
target_wid=$(jq -r '.id' <<<"$target_json")
target_pid=$(jq -r '.pid // 0' <<<"$target_json")
source_title=$(jq -r '.title // ""' <<<"$source_json")
target_title=$(jq -r '.title // ""' <<<"$target_json")

"$APP" --focus="$target_wid" >/dev/null
sleep "$(sleep_ms "$SETTLE_MS")"
"$APP" --focus="$source_wid" >/dev/null
sleep "$(sleep_ms "$SETTLE_MS")"
state_after_source=$(selection_state_after_show)
selected_wid=$(jq -r '.selectedWindow.id // 0' <<<"$state_after_source")
selected_app=$(jq -r '.selectedWindow.appName // ""' <<<"$state_after_source")
selected_index=$(jq -r '.selectedIndex // -1' <<<"$state_after_source")
if [ "$selected_wid" != "$target_wid" ]; then
  echo "Refusing switch: actual AltTab selected window is not target. selected_index=$selected_index selected=($selected_wid,$selected_app)" >&2
  exit 3
fi

"$SAMPLER" --target-wid "$target_wid" --target-pid "$target_pid" --duration-ms "$DURATION_MS" --interval-ms "$INTERVAL_MS" > "$OUT" &
sampler_pid=$!
sleep "$(sleep_ms "$PRE_MS")"
"$APP" --show=0 >/dev/null
sleep "$(sleep_ms "$SHOW_TO_FOCUS_MS")"
"$APP" --focus-target >/dev/null
if [ "$SHIFT_PROBE" = "1" ]; then
  sleep "$(sleep_ms "$PROBE_DELAY_MS")"
  "$PROBER" >/dev/null
fi
wait "$sampler_pid"
final_front=$(osascript -e 'tell application "System Events" to get name of first application process whose frontmost is true' 2>/dev/null || true)

python3 - "$OUT" "$PRE_MS" "$source_wid" "$target_wid" "$target_pid" "$SOURCE_APP" "$TARGET_APP" "$source_title" "$target_title" "$final_front" "$selected_index" "$selected_wid" "$selected_app" "$SHOW_TO_FOCUS_MS" "$SHIFT_PROBE" <<'PY'
import json, sys
path, pre_ms, source_wid, target_wid, target_pid = sys.argv[1], float(sys.argv[2]), int(sys.argv[3]), int(sys.argv[4]), int(sys.argv[5])
source_app, target_app, source_title, target_title, final_front = sys.argv[6:11]
selected_index, selected_wid, selected_app, show_to_focus_ms, shift_probe = sys.argv[11], int(sys.argv[12]), sys.argv[13], sys.argv[14], sys.argv[15]
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
first_front = next((r["t_ms"] - pre_ms for r in after if r.get("front_pid") == target_pid), None)
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
print(f"switch {source_app!r}->{target_app!r} show_to_focus_ms={show_to_focus_ms} source_wid={source_wid} target_wid={target_wid}")
print(f"source_title={source_title[:80]!r}")
print(f"target_title={target_title[:80]!r}")
print(f"selected_index_after_source={selected_index} selected=({selected_wid},{selected_app!r}) final_front={final_front!r} shift_probe={shift_probe}")
print(f"samples={len(rows)} after_switch={len(after)} file={path}")
print(f"pre_top8={[(w, o) for w, _, o in pre_top[:8]]}")
print(f"final_top8={final_top8}")
print(f"first_target_z0_ms={first_z0 if first_z0 is not None else 'never'} first_front_pid_ms={first_front if first_front is not None else 'never'}")
print(f"flicker_after_z0_samples={len(flickers)} source_reappears_after_z0_samples={len(source_after_z0)} target_missing_samples={missing}")
print(f"same_app_above_max={same_above_max} same_app_above_after_z0_max={same_above_after_z0}")
print(f"sibling_intrusions_after_z0_max={sibling_intrusion_max} first={sibling_intrusion_first if sibling_intrusion_first else 'none'}")
print("app_top_changes_ms=(top_wid,top_owner,target_z,same_app_above)")
for item in top_changes[:24]:
    print(f"  {item[0]} {item[1]}")
if len(top_changes) > 24:
    print(f"  ... {len(top_changes) - 24} more")
failed = first_z0 is None or final_row.get("top_wid") != target_wid or len(flickers) > 0 or sibling_intrusion_max > 0
sys.exit(1 if failed else 0)
PY
