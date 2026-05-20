#!/usr/bin/env bash
set -euo pipefail

APP=${ALTTAB_APP:-/Applications/AltTab.app/Contents/MacOS/AltTab}
if [ -z "${ALTTAB_DYLIB_OVERRIDE:-}" ] && [ -f "$(pwd)/dev/AltTabCore.dylib" ]; then
  export ALTTAB_DYLIB_OVERRIDE="$(pwd)/dev/AltTabCore.dylib"
fi

APP_REGEX=${APP_REGEX:-Terminal}
SOURCE_INDEX=${SOURCE_INDEX:-0}
KEY_CODE=${KEY_CODE:-45}
PRE_MS=${PRE_MS:-250}
DURATION_MS=${DURATION_MS:-2200}
INTERVAL_MS=${INTERVAL_MS:-10}
SETTLE_MS=${SETTLE_MS:-650}
MAX_NEW_APPEAR_MS=${MAX_NEW_APPEAR_MS:-2000}
MAX_NEW_Z0_AFTER_SEEN_MS=${MAX_NEW_Z0_AFTER_SEEN_MS:-250}
CLOSE_NEW=${CLOSE_NEW:-0}
SAMPLER=${SAMPLER:-/tmp/alttab-z-order-sampler}
KEYER=${KEYER:-/tmp/alttab-post-key-combo}
MARKER=${MARKER:-created-window-front-$(date +%Y%m%d-%H%M%S)-$$}
OUT=${OUT:-/tmp/alttab-created-window-front-${MARKER}.jsonl}
LOG_SCAN=${LOG_SCAN:-/tmp/alttab-created-window-front-${MARKER}.logscan.txt}

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

bash ai/eval-user-idle-guard.sh "created-window-$APP_REGEX"

alttab() {
  local out status
  set +e
  out=$("$APP" "$@" 2>&1)
  status=$?
  set -e
  printf '%s\n' "$out" | sed -n '/^[[:space:]]*[{[]/,$p'
  return "$status"
}

sleep_ms() {
  python3 - "$1" <<'PY'
import sys
print(int(sys.argv[1]) / 1000)
PY
}

pick_window() {
  alttab --detailed-list | jq -c --arg app "$APP_REGEX" --argjson index "$SOURCE_INDEX" '[.windows[] | select((.appName | test($app; "i")) and (.isMinimized | not) and (.isDisplayable // true))][$index]'
}

app_wids() {
  alttab --detailed-list | jq -r --arg app "$APP_REGEX" '.windows[] | select((.appName | test($app; "i")) and (.isDisplayable // true)) | .id'
}

if [ ! -x "$SAMPLER" ] || [ ai/z-order-sampler.swift -nt "$SAMPLER" ]; then
  swiftc ai/z-order-sampler.swift -o "$SAMPLER"
fi
if [ ! -x "$KEYER" ] || [ ai/post-key-combo.swift -nt "$KEYER" ]; then
  swiftc ai/post-key-combo.swift -o "$KEYER"
fi

MARKER="$MARKER" POPUP_STORM_CONTEXT="created-window-preflight" bash ai/eval-popup-storm-guard.sh
source_json=$(pick_window)
if [ -z "$source_json" ] || [ "$source_json" = "null" ]; then
  echo "FAIL: no source window matching $APP_REGEX" >&2
  exit 2
fi
source_wid=$(jq -r '.id' <<<"$source_json")
source_pid=$(jq -r '.pid' <<<"$source_json")
source_title=$(jq -r '.title // ""' <<<"$source_json")
before_wids=$(app_wids | sort -n | tr '\n' ' ')

printf '=== EVAL MARKER: %s ===\n' "$MARKER" >> /tmp/alttab-run.log
alttab --focus="$source_wid" >/dev/null
sleep "$(sleep_ms "$SETTLE_MS")"
"$SAMPLER" --target-pid "$source_pid" --target-owner "$APP_REGEX" --duration-ms "$DURATION_MS" --interval-ms "$INTERVAL_MS" > "$OUT" &
sampler_pid=$!
sleep "$(sleep_ms "$PRE_MS")"
"$KEYER" "$KEY_CODE" >/dev/null
wait "$sampler_pid"
sleep "$(sleep_ms 250)"
after_wids=$(app_wids | sort -n | tr '\n' ' ')
new_wid=$(python3 - "$before_wids" "$after_wids" <<'PY'
import sys
before = set(x for x in sys.argv[1].split() if x)
after = [x for x in sys.argv[2].split() if x]
new = [x for x in after if x not in before]
print(new[-1] if new else "")
PY
)

if [ -z "$new_wid" ]; then
  printf '=== EVAL END MARKER: %s ===\n' "$MARKER" >> /tmp/alttab-run.log
  echo "FAIL: no new $APP_REGEX window detected. before=[$before_wids] after=[$after_wids]" >&2
  exit 3
fi

printf '=== EVAL END MARKER: %s ===\n' "$MARKER" >> /tmp/alttab-run.log
scan_rc=0
python3 ai/eval-log-anomalies.py --marker "$MARKER" --end-marker "=== EVAL END MARKER: $MARKER ===" --strict > "$LOG_SCAN" || scan_rc=$?
if [ "$scan_rc" -ne 0 ]; then
  cat "$LOG_SCAN"
fi

set +e
python3 - "$OUT" "$PRE_MS" "$new_wid" "$source_wid" "$MAX_NEW_APPEAR_MS" "$MAX_NEW_Z0_AFTER_SEEN_MS" "$source_title" <<'PY'
import json
import sys

path, pre_ms, new_wid, source_wid, max_appear_ms, max_z0_after_seen_ms, source_title = sys.argv[1], float(sys.argv[2]), int(sys.argv[3]), int(sys.argv[4]), float(sys.argv[5]), float(sys.argv[6]), sys.argv[7]
rows = []
with open(path) as f:
    for line in f:
        try:
            rows.append(json.loads(line))
        except json.JSONDecodeError:
            pass
after = [r for r in rows if r.get("t_ms", 0) >= pre_ms]
first_seen = next((r["t_ms"] - pre_ms for r in after if new_wid in (r.get("top_wids") or [])), None)
first_z0 = next((r["t_ms"] - pre_ms for r in after if (r.get("top_wids") or [None])[0] == new_wid), None)
z0_after_seen = None if first_seen is None or first_z0 is None else first_z0 - first_seen
source_reappears = [r for r in after if first_z0 is not None and r["t_ms"] - pre_ms > first_z0 and (r.get("top_wids") or [None])[0] == source_wid]
final = after[-1] if after else {}
final_top = (final.get("top_wids") or [None])[0]
print(f"created-window app_source_title={source_title[:60]!r} source_wid={source_wid} new_wid={new_wid} first_seen_ms={first_seen} first_z0_ms={first_z0} z0_after_seen_ms={z0_after_seen} final_top={final_top} source_reappears={len(source_reappears)}")
if first_seen is None:
    print("FAIL: new window never appeared in sampled top windows", file=sys.stderr)
    sys.exit(5)
if first_seen > max_appear_ms:
    print(f"FAIL: new window first appeared after {first_seen:.1f}ms > {max_appear_ms:.1f}ms", file=sys.stderr)
    sys.exit(6)
if first_z0 is None:
    print("FAIL: new window never reached visual z0", file=sys.stderr)
    sys.exit(7)
if z0_after_seen is None or z0_after_seen > max_z0_after_seen_ms:
    print(f"FAIL: new window z0-after-seen took {z0_after_seen:.1f}ms > {max_z0_after_seen_ms:.1f}ms", file=sys.stderr)
    sys.exit(8)
if final_top != new_wid:
    print(f"FAIL: final top {final_top} != new window {new_wid}", file=sys.stderr)
    sys.exit(9)
if source_reappears:
    print("FAIL: source window reappeared above new window after z0", file=sys.stderr)
    sys.exit(10)
PY
eval_rc=$?
set -e

cat "$LOG_SCAN"
if [ "$CLOSE_NEW" = "1" ]; then
  if [[ "$APP_REGEX" =~ [Tt]erminal ]]; then
    osascript -e 'tell application "System Events" to keystroke "exit"' -e 'tell application "System Events" to key code 36' >/dev/null 2>&1 || true
    sleep "$(sleep_ms 250)"
  fi
  osascript -e 'tell application "System Events" to keystroke "w" using command down' >/dev/null 2>&1 || true
fi
MARKER="$MARKER" POPUP_STORM_CONTEXT="created-window-post" bash ai/eval-popup-storm-guard.sh
if [ "$scan_rc" -ne 0 ]; then exit "$scan_rc"; fi
exit "$eval_rc"
