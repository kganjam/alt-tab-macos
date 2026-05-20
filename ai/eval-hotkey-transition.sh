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
SOURCE_INDEX=${SOURCE_INDEX:-0}
TARGET_INDEX=${TARGET_INDEX:-0}
DURATION_MS=${DURATION_MS:-3000}
INTERVAL_MS=${INTERVAL_MS:-5}
PRE_MS=${PRE_MS:-250}
SETTLE_MS=${SETTLE_MS:-700}
KEY_DOWN_MS=${KEY_DOWN_MS:-45}
HOLD_MODIFIER=${HOLD_MODIFIER:-}
REQUIRE_TARGET_SECOND=${REQUIRE_TARGET_SECOND:-1}
PREFLIGHT_SHOW_MS=${PREFLIGHT_SHOW_MS:-80}
SHIFT_PROBE=${SHIFT_PROBE:-0}
PROBE_DELAY_MS=${PROBE_DELAY_MS:-250}
SAMPLER=${SAMPLER:-/tmp/alttab-z-order-sampler}
POSTER=${POSTER:-/tmp/alttab-post-alt-tab}
PROBER=${PROBER:-/tmp/alttab-post-shift-probe}
OUT=${OUT:-/tmp/alttab-hotkey-zorder-$(date +%Y%m%d-%H%M%S).jsonl}

if [ "${ALLOW_SYNTHETIC_HOTKEY_TESTS:-0}" != "1" ]; then
  echo "Refusing to post global hotkeys. Set ALLOW_SYNTHETIC_HOTKEY_TESTS=1 only on an isolated test desktop." >&2
  exit 2
fi
if [[ "$SOURCE_APP $TARGET_APP" =~ [Tt]erminal ]] && [ "${ALLOW_TERMINAL_HOTKEY_TESTS:-0}" != "1" ]; then
  echo "Refusing Terminal hotkey test on the live desktop. Use a sacrificial app/window or set ALLOW_TERMINAL_HOTKEY_TESTS=1 explicitly." >&2
  exit 2
fi

if [ ! -x "$SAMPLER" ] || [ ai/z-order-sampler.swift -nt "$SAMPLER" ]; then
  swiftc ai/z-order-sampler.swift -o "$SAMPLER"
fi
if [ ! -x "$POSTER" ] || [ ai/post-alt-tab.swift -nt "$POSTER" ]; then
  swiftc ai/post-alt-tab.swift -o "$POSTER"
fi
if [ "$SHIFT_PROBE" = "1" ] && { [ ! -x "$PROBER" ] || [ ai/post-shift-probe.swift -nt "$PROBER" ]; }; then
  swiftc ai/post-shift-probe.swift -o "$PROBER"
fi

if [ -z "$HOLD_MODIFIER" ]; then
  hold_pref=$(defaults read com.lwouis.alt-tab-macos holdShortcut 2>/dev/null | awk -F'= ' '/string/{gsub(/[\";]/, "", $2); print $2; exit}' || true)
  case "$hold_pref" in
    *2318*|*⌘*) HOLD_MODIFIER=command ;;
    *2325*|*⌥*) HOLD_MODIFIER=option ;;
    *2303*|*⌃*) HOLD_MODIFIER=control ;;
    *21E7*|*⇧*) HOLD_MODIFIER=shift ;;
    *) HOLD_MODIFIER=option ;;
  esac
fi

pick_window() {
  local app=$1
  local index=$2
  alttab --detailed-list | jq -c --arg app "$app" --argjson index "$index" '[.windows | sort_by(.lastFocusOrder)[] | select((.appName | test($app; "i")) and (.isMinimized | not))][$index]'
}

selection_state_after_show() {
  alttab --show=0 >/dev/null
  sleep "$(python3 - <<PY
print($PREFLIGHT_SHOW_MS / 1000)
PY
)"
  local state
  state=$(alttab --selection-state)
  alttab --hide >/dev/null || true
  printf '%s\n' "$state"
}

source_json=$(pick_window "$SOURCE_APP" "$SOURCE_INDEX")
target_json=$(pick_window "$TARGET_APP" "$TARGET_INDEX")
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

for attempt in 1 2 3; do
  alttab --focus="$target_wid" >/dev/null
  sleep "$(python3 - <<PY
print($SETTLE_MS / 1000)
PY
)"
  alttab --focus="$source_wid" >/dev/null
  sleep "$(python3 - <<PY
print($SETTLE_MS / 1000)
PY
)"
  state_after_source=$(selection_state_after_show)
  selected_wid=$(jq -r '.selectedWindow.id // 0' <<<"$state_after_source")
  selected_app=$(jq -r '.selectedWindow.appName // ""' <<<"$state_after_source")
  expected_at=$(jq -r '.selectedIndex // -1' <<<"$state_after_source")
  second_wid=$selected_wid
  second_app=$selected_app
  if [ "$REQUIRE_TARGET_SECOND" != "1" ] || [ "$selected_wid" = "$target_wid" ]; then
    break
  fi
done
if [ "$REQUIRE_TARGET_SECOND" = "1" ] && [ "${selected_wid:-0}" != "$target_wid" ]; then
  echo "Refusing hotkey: actual AltTab selected window is not target. selected_index=${expected_at:-missing} selected=($second_wid,$second_app)" >&2
  exit 3
fi

"$SAMPLER" --target-wid "$target_wid" --target-pid "$target_pid" --duration-ms "$DURATION_MS" --interval-ms "$INTERVAL_MS" > "$OUT" &
sampler_pid=$!
sleep "$(python3 - <<PY
print($PRE_MS / 1000)
PY
)"
"$POSTER" "$HOLD_MODIFIER" "$KEY_DOWN_MS" >/dev/null
if [ "$SHIFT_PROBE" = "1" ]; then
  sleep "$(python3 - <<PY
print($PROBE_DELAY_MS / 1000)
PY
)"
  "$PROBER" >/dev/null
fi
wait "$sampler_pid"
final_front=$(osascript -e 'tell application "System Events" to get name of first application process whose frontmost is true' 2>/dev/null || true)

python3 - "$OUT" "$PRE_MS" "$source_wid" "$target_wid" "$target_pid" "$SOURCE_APP" "$TARGET_APP" "$source_title" "$target_title" "$final_front" "$expected_at" "$second_wid" "$second_app" "$KEY_DOWN_MS" "$HOLD_MODIFIER" <<'PY'
import json, sys
path, pre_ms, source_wid, target_wid, target_pid = sys.argv[1], float(sys.argv[2]), int(sys.argv[3]), int(sys.argv[4]), int(sys.argv[5])
source_app, target_app, source_title, target_title, final_front = sys.argv[6:11]
expected_at, second_wid, second_app, key_down_ms, hold_modifier = sys.argv[11], int(sys.argv[12]), sys.argv[13], sys.argv[14], sys.argv[15]
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
raw_changes = []
last = None
last_raw = None
for r in after:
    cur = (r.get("top_wid"), r.get("top_owner"), r.get("target_z"), r.get("same_app_above"))
    raw = (r.get("raw_top_wid"), r.get("raw_top_owner"))
    if cur != last:
        top_changes.append((round(r["t_ms"] - pre_ms, 1), cur))
        last = cur
    if raw != last_raw:
        raw_changes.append((round(r["t_ms"] - pre_ms, 1), raw))
        last_raw = raw
print(f"hotkey {source_app!r}->{target_app!r} hold={hold_modifier} key_down_ms={key_down_ms} source_wid={source_wid} target_wid={target_wid}")
print(f"source_title={source_title[:80]!r}")
print(f"target_title={target_title[:80]!r}")
print(f"target_index_after_source={expected_at or 'missing'} second_after_source=({second_wid},{second_app!r}) final_front={final_front!r}")
print(f"samples={len(rows)} after_hotkey={len(after)} file={path}")
print(f"pre_top8={[(w, o) for w, _, o in pre_top[:8]]}")
print(f"final_top8={final_top8}")
print(f"first_target_z0_ms={first_z0 if first_z0 is not None else 'never'} first_front_pid_ms={first_front if first_front is not None else 'never'}")
print(f"flicker_after_z0_samples={len(flickers)} source_reappears_after_z0_samples={len(source_after_z0)} target_missing_samples={missing}")
print(f"same_app_above_max={same_above_max} same_app_above_after_z0_max={same_above_after_z0}")
print(f"sibling_intrusions_after_z0_max={sibling_intrusion_max} first={sibling_intrusion_first if sibling_intrusion_first else 'none'}")
print("raw_top_changes_ms=(raw_top_wid,raw_top_owner)")
for item in raw_changes[:18]:
    print(f"  {item[0]} {item[1]}")
if len(raw_changes) > 18:
    print(f"  ... {len(raw_changes) - 18} more")
print("app_top_changes_ms=(top_wid,top_owner,target_z,same_app_above)")
for item in top_changes[:24]:
    print(f"  {item[0]} {item[1]}")
if len(top_changes) > 24:
    print(f"  ... {len(top_changes) - 24} more")
failed = first_z0 is None or final_row.get("top_wid") != target_wid or len(flickers) > 0 or sibling_intrusion_max > 0
sys.exit(1 if failed else 0)
PY
