#!/usr/bin/env bash
set -euo pipefail

APP=${ALTTAB_APP:-/Applications/AltTab.app/Contents/MacOS/AltTab}
if [ -z "${ALTTAB_DYLIB_OVERRIDE:-}" ] && [ -f "$(pwd)/dev/AltTabCore.dylib" ]; then
  export ALTTAB_DYLIB_OVERRIDE="$(pwd)/dev/AltTabCore.dylib"
fi
TARGET_APP=${1:-Safari}
TARGET_WID=${TARGET_WID:-}
TARGET_INDEX=${TARGET_INDEX:-0}
DURATION_MS=${DURATION_MS:-2500}
INTERVAL_MS=${INTERVAL_MS:-5}
PRE_MS=${PRE_MS:-200}
SAMPLER=${SAMPLER:-/tmp/alttab-z-order-sampler}
PROBER=${PROBER:-/tmp/alttab-post-shift-probe}
OUT=${OUT:-/tmp/alttab-zorder-$(date +%Y%m%d-%H%M%S).jsonl}
SHIFT_PROBE=${SHIFT_PROBE:-0}
PROBE_DELAY_MS=${PROBE_DELAY_MS:-250}

if [ ! -x "$SAMPLER" ] || [ ai/z-order-sampler.swift -nt "$SAMPLER" ]; then
  swiftc ai/z-order-sampler.swift -o "$SAMPLER"
fi
if [ "$SHIFT_PROBE" = "1" ] && { [ ! -x "$PROBER" ] || [ ai/post-shift-probe.swift -nt "$PROBER" ]; }; then
  swiftc ai/post-shift-probe.swift -o "$PROBER"
fi

if [ -n "$TARGET_WID" ]; then
  target_json=$("$APP" --detailed-list | jq -c --argjson wid "$TARGET_WID" 'first(.windows[] | select(.id == $wid))')
else
  target_json=$("$APP" --detailed-list | jq -c --arg app "$TARGET_APP" --argjson index "$TARGET_INDEX" '[.windows[] | select(.appName | test($app; "i"))][$index]')
fi
if [ -z "$target_json" ] || [ "$target_json" = "null" ]; then
  echo "No target window matching app pattern: $TARGET_APP" >&2
  exit 2
fi

wid=$(jq -r '.id' <<<"$target_json")
pid=$(jq -r '.pid // 0' <<<"$target_json")
title=$(jq -r '.title // ""' <<<"$target_json")

"$SAMPLER" --target-wid "$wid" --target-pid "$pid" --duration-ms "$DURATION_MS" --interval-ms "$INTERVAL_MS" > "$OUT" &
sampler_pid=$!
sleep "$(python3 - <<PY
print($PRE_MS / 1000)
PY
)"
focus_started_ns=$(python3 - <<'PY'
import time
print(time.monotonic_ns())
PY
)
"$APP" --focus="$wid" >/dev/null
if [ "$SHIFT_PROBE" = "1" ]; then
  sleep "$(python3 - <<PY
print($PROBE_DELAY_MS / 1000)
PY
)"
  "$PROBER" >/dev/null
fi
wait "$sampler_pid"
final_front=$(osascript -e 'tell application "System Events" to get name of first application process whose frontmost is true' 2>/dev/null || true)
probe_label=off
if [ "$SHIFT_PROBE" = "1" ]; then
  probe_label="shift@${PROBE_DELAY_MS}ms"
fi

python3 - "$OUT" "$PRE_MS" "$wid" "$pid" "$TARGET_APP" "$title" "$final_front" "$probe_label" <<'PY'
import json, sys
path, pre_ms, wid, pid, app, title, final_front, probe_label = sys.argv[1], float(sys.argv[2]), int(sys.argv[3]), int(sys.argv[4]), sys.argv[5], sys.argv[6], sys.argv[7], sys.argv[8]
rows = []
with open(path) as f:
    for line in f:
        try:
            rows.append(json.loads(line))
        except json.JSONDecodeError:
            pass
if pid == 0:
    pid = next((int(r.get("target_pid") or 0) for r in rows if int(r.get("target_pid") or 0) != 0), 0)
after = [r for r in rows if r["t_ms"] >= pre_ms]
before = [r for r in rows if r["t_ms"] < pre_ms]
baseline = before[-1] if before else {}
first_z0 = next((r["t_ms"] - pre_ms for r in after if r.get("target_z") == 0), None)
first_front = next((r["t_ms"] - pre_ms for r in after if r.get("front_pid") == pid), None)
post_z0 = [r for r in after if first_z0 is not None and r["t_ms"] - pre_ms >= first_z0]
flickers = [r for r in post_z0 if r.get("target_z") != 0]
same_above_max = max((r.get("same_app_above") or 0 for r in after), default=0)
same_above_after_z0 = max((r.get("same_app_above") or 0 for r in post_z0), default=0)
same_top8_after_z0 = max((r.get("same_app_top8") or 0 for r in post_z0), default=0)
missing = sum(1 for r in after if r.get("target_z") is None)
pre_top = list(zip(baseline.get("top_wids", []), baseline.get("top_pids", []), baseline.get("top_owners", [])))
pre_rank = {int(w): i for i, (w, _, _) in enumerate(pre_top)}
divider = next(((int(w), int(p), o, i) for i, (w, p, o) in enumerate(pre_top) if int(w) != wid and int(p) != pid), None)
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
    for i, (w, p, o) in enumerate(top):
        w, p = int(w), int(p)
        if w == wid or p != pid or i >= divider_actual_rank:
            continue
        if pre_rank.get(w, 10**9) > divider_pre_rank:
            bad.append(w)
    return bad
sibling_intrusion_rows = [(r, sibling_intrusions(r)) for r in post_z0]
sibling_intrusion_max = max((len(wids) for _, wids in sibling_intrusion_rows), default=0)
sibling_intrusion_first = next(((r["t_ms"] - pre_ms, wids) for r, wids in sibling_intrusion_rows if wids), None)
final_row = after[-1] if after else (rows[-1] if rows else {})
final_top8 = list(zip(final_row.get("top_wids", []), final_row.get("top_owners", [])))[:8]
top_changes = []
last = None
for r in after:
    cur = (r.get("top_wid"), r.get("top_owner"), r.get("target_z"), r.get("same_app_above"))
    if cur != last:
        top_changes.append((round(r["t_ms"] - pre_ms, 1), cur))
        last = cur
print(f"target app={app!r} pid={pid} wid={wid} title={title[:80]!r}")
print(f"focus_probe={probe_label}")
print(f"final_system_frontmost={final_front!r}")
print(f"samples={len(rows)} after_focus={len(after)} file={path}")
print(f"pre_top8={[(w, o) for w, _, o in pre_top[:8]]}")
print(f"final_top8={final_top8}")
print(f"first_target_z0_ms={first_z0 if first_z0 is not None else 'never'} first_front_pid_ms={first_front if first_front is not None else 'never'}")
print(f"flicker_after_z0_samples={len(flickers)} target_missing_samples={missing}")
print(f"same_app_above_max={same_above_max} same_app_above_after_z0_max={same_above_after_z0} same_app_top8_after_z0_max={same_top8_after_z0}")
print(f"sibling_intrusions_after_z0_max={sibling_intrusion_max} first={sibling_intrusion_first if sibling_intrusion_first else 'none'}")
print("top_changes_ms=(top_wid,top_owner,target_z,same_app_above)")
for item in top_changes[:24]:
    print(f"  {item[0]} {item[1]}")
if len(top_changes) > 24:
    print(f"  ... {len(top_changes) - 24} more")
PY
