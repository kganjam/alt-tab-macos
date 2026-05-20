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

SOURCE_APP=${SOURCE_APP:-Terminal}
SOURCE_INDEX=${SOURCE_INDEX:-0}
TARGET_OWNER=${TARGET_OWNER:-Outlook}
LAUNCH_COMMAND=${LAUNCH_COMMAND:-}
LAUNCH_APP=${LAUNCH_APP:-}
LAUNCH_BUNDLE=${LAUNCH_BUNDLE:-}
SIMULATE_EXTERNAL_KEY=${SIMULATE_EXTERNAL_KEY:-0}
FAIL_KEY_EVENTS=${FAIL_KEY_EVENTS:-1}
DURATION_MS=${DURATION_MS:-3500}
INTERVAL_MS=${INTERVAL_MS:-8}
PRE_MS=${PRE_MS:-300}
SETTLE_MS=${SETTLE_MS:-900}
MAX_TO_FRONT_MS=${MAX_TO_FRONT_MS:-1800}
LAUNCH_COMMAND_TIMEOUT_MS=${LAUNCH_COMMAND_TIMEOUT_MS:-2500}
SAMPLER=${SAMPLER:-/tmp/alttab-z-order-sampler}
POST_MODIFIER=${POST_MODIFIER:-/tmp/alttab-post-modifier}
OUT=${OUT:-/tmp/alttab-external-launch-$(date +%Y%m%d-%H%M%S).jsonl}
MARKER=${MARKER:-external-launch-$(date +%Y%m%d-%H%M%S)-$$}
LOG_SCAN=${LOG_SCAN:-/tmp/alttab-external-launch-${MARKER}.logscan.txt}
Z_SCAN=${Z_SCAN:-/tmp/alttab-external-launch-${MARKER}.zscan.txt}
if [ -d "$OUT" ]; then
  OUT="$OUT/zsamples.jsonl"
fi

bash ai/eval-user-idle-guard.sh "external-$SOURCE_APP-to-$TARGET_OWNER"

popup_guard() {
  MARKER="$MARKER" POPUP_STORM_CONTEXT="$1" bash ai/eval-popup-storm-guard.sh
}
popup_guard "external-preflight-$SOURCE_APP-$TARGET_OWNER"

if [ ! -x "$SAMPLER" ] || [ ai/z-order-sampler.swift -nt "$SAMPLER" ]; then
  swiftc ai/z-order-sampler.swift -o "$SAMPLER"
fi
if [ "$SIMULATE_EXTERNAL_KEY" = "1" ] && { [ ! -x "$POST_MODIFIER" ] || [ ai/post-modifier.swift -nt "$POST_MODIFIER" ]; }; then
  swiftc ai/post-modifier.swift -o "$POST_MODIFIER"
fi

sleep_ms() {
  python3 - "$1" <<'PY'
import sys
print(int(sys.argv[1]) / 1000)
PY
}

pick_source() {
  alttab --detailed-list | jq -c --arg app "$SOURCE_APP" --argjson index "$SOURCE_INDEX" '[.windows[] | select((.appName | test($app; "i")) and (.isMinimized | not))][$index]'
}

find_launch_bundle() {
  if [ -n "$LAUNCH_BUNDLE" ]; then
    printf '%s\n' "$LAUNCH_BUNDLE"
    return
  fi
  local bundle
  bundle=$(find "$HOME/Applications (Parallels)" /Applications -maxdepth 4 -name "${TARGET_OWNER}.app" -print -quit 2>/dev/null)
  if [ -n "$bundle" ]; then
    printf '%s\n' "$bundle"
    return
  fi
  find "$HOME/Applications (Parallels)" /Applications -maxdepth 4 -name "${TARGET_OWNER}*.app" -print -quit 2>/dev/null
}

launch_target() {
  if [ -n "$LAUNCH_COMMAND" ]; then
    python3 - "$LAUNCH_COMMAND" "$LAUNCH_COMMAND_TIMEOUT_MS" <<'PY'
import subprocess, sys
command, timeout_ms = sys.argv[1], int(sys.argv[2])
try:
    subprocess.run(command, shell=True, timeout=timeout_ms / 1000, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
except subprocess.TimeoutExpired:
    pass
PY
    return
  fi
  if [ -n "$LAUNCH_BUNDLE" ] || [ -z "$LAUNCH_APP" ]; then
    local bundle
    bundle=$(find_launch_bundle)
    if [ -n "$bundle" ]; then
      open "$bundle"
      return
    fi
  fi
  open -a "${LAUNCH_APP:-$TARGET_OWNER}"
}

source_json=$(pick_source)
if [ -z "$source_json" ] || [ "$source_json" = "null" ]; then
  echo "No source window matching app pattern: $SOURCE_APP" >&2
  exit 2
fi
source_wid=$(jq -r '.id' <<<"$source_json")
source_pid=$(jq -r '.pid // 0' <<<"$source_json")

popup_guard "external-before-source-focus-$SOURCE_APP"
alttab --focus="$source_wid" >/dev/null
sleep "$(sleep_ms "$SETTLE_MS")"
popup_guard "external-before-marker-$TARGET_OWNER"
printf '=== EVAL MARKER: %s ===\n' "$MARKER" >> /tmp/alttab-run.log
"$SAMPLER" --target-owner "$TARGET_OWNER" --duration-ms "$DURATION_MS" --interval-ms "$INTERVAL_MS" > "$OUT" &
sampler_pid=$!
sleep "$(sleep_ms "$PRE_MS")"
if [ "$SIMULATE_EXTERNAL_KEY" = "1" ]; then
  "$POST_MODIFIER" 56
  sleep "$(sleep_ms 60)"
fi
launch_target
wait "$sampler_pid"
popup_guard "external-after-sampler-$TARGET_OWNER"
printf '=== EVAL END MARKER: %s ===\n' "$MARKER" >> /tmp/alttab-run.log

set +e
python3 - "$OUT" "$PRE_MS" "$TARGET_OWNER" "$MAX_TO_FRONT_MS" > "$Z_SCAN" <<'PY'
import json, sys
path, pre_ms, target_owner, max_to_front_ms = sys.argv[1], float(sys.argv[2]), sys.argv[3], float(sys.argv[4])
rows = []
with open(path) as f:
    for line in f:
        try:
            rows.append(json.loads(line))
        except json.JSONDecodeError:
            pass
after = [r for r in rows if r["t_ms"] >= pre_ms]
first_z0 = next((r["t_ms"] - pre_ms for r in after if r.get("target_z") == 0), None)
post_z0 = [r for r in after if first_z0 is not None and r["t_ms"] - pre_ms >= first_z0]
flickers = [r for r in post_z0 if r.get("target_z") != 0]
missing = sum(1 for r in after if r.get("target_z") is None)
final = after[-1] if after else (rows[-1] if rows else {})
top_changes = []
last = None
for r in after:
    cur = (r.get("top_wid"), r.get("top_owner"), r.get("target_z"), r.get("front_name"))
    if cur != last:
        top_changes.append((round(r["t_ms"] - pre_ms, 1), cur))
        last = cur
final_top_owner = final.get("top_owner") or ""
final_front = final.get("front_name") or ""
front_ok = target_owner.lower() in final_front.lower()
top_ok = target_owner.lower() in final_top_owner.lower()
latency_ok = first_z0 is not None and first_z0 <= max_to_front_ms
print(f"external-launch target_owner={target_owner!r} final_front={final_front!r}")
print(f"samples={len(rows)} after_launch={len(after)} file={path}")
print(f"first_target_z0_ms={first_z0 if first_z0 is not None else 'never'} max_to_front_ms={max_to_front_ms}")
print(f"flicker_after_z0_samples={len(flickers)} target_missing_samples={missing}")
print(f"final_top=({final.get('top_wid')},{final_top_owner!r}) final_front_name={final.get('front_name')!r}")
print("top_changes_ms=(top_wid,top_owner,target_z,front_name)")
for item in top_changes[:24]:
    print(f"  {item[0]} {item[1]}")
if len(top_changes) > 24:
    print(f"  ... {len(top_changes) - 24} more")
failed = not top_ok or not front_ok or not latency_ok or bool(flickers)
sys.exit(1 if failed else 0)
PY
z_status=$?
cat "$Z_SCAN"
log_args=(--marker "$MARKER" --end-marker "=== EVAL END MARKER: $MARKER ===" --forbid-focus-path --fail-front-restore --strict)
if [ "$FAIL_KEY_EVENTS" = "1" ]; then
  log_args+=(--fail-key-events)
fi
python3 ai/eval-log-anomalies.py "${log_args[@]}" > "$LOG_SCAN"
log_status=$?
cat "$LOG_SCAN"
set -e
if [ "$z_status" -ne 0 ] || [ "$log_status" -ne 0 ]; then
  exit 1
fi
