#!/usr/bin/env bash
set -euo pipefail

APP=${APP:-/Applications/AltTab.app/Contents/MacOS/AltTab}
if [ -z "${ALTTAB_DYLIB_OVERRIDE:-}" ] && [ -f "$(pwd)/dev/AltTabCore.dylib" ]; then
  export ALTTAB_DYLIB_OVERRIDE="$(pwd)/dev/AltTabCore.dylib"
fi
SHORTCUT_INDEX=${SHORTCUT_INDEX:-0}
SHOW_WAIT_MS=${SHOW_WAIT_MS:-2500}
MIN_DISPLAYABLE=${MIN_DISPLAYABLE:-3}
MIN_THUMBNAIL_RATIO=${MIN_THUMBNAIL_RATIO:-0.75}
MAX_STALE_MS=${MAX_STALE_MS:-10000}
CHECK_LIMIT=${CHECK_LIMIT:-48}
VISIBLE_ONLY=${VISIBLE_ONLY:-1}
OWNER_REGEX=${OWNER_REGEX:-}
MARKER=${MARKER:-thumbnail-coverage-$(date +%Y%m%d-%H%M%S)-$$}
LOG_SCAN=${LOG_SCAN:-/tmp/alttab-thumbnail-coverage-${MARKER}.logscan.txt}

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

bash ai/eval-user-idle-guard.sh "thumbnail-coverage"

alttab() {
  local out status
  set +e
  out=$("$APP" "$@" 2>&1)
  status=$?
  set -e
  printf '%s\n' "$out" | sed -n '/^[[:space:]]*[{[]/,$p'
  return "$status"
}

bash ai/eval-popup-storm-guard.sh thumbnail-preflight
before_pids="$(pgrep -f '^/Applications/AltTab.app/Contents/MacOS/AltTab' | sort | tr '\n' ' ')"
printf '=== EVAL MARKER: %s ===\n' "$MARKER" >> /tmp/alttab-run.log
alttab --show="$SHORTCUT_INDEX" >/dev/null
sleep "$(python3 - <<PY
print(max(0, int("$SHOW_WAIT_MS")) / 1000)
PY
)"

tmp_json="$(mktemp "${TMPDIR:-/tmp}/alttab-thumbnail-state.XXXXXX")"
snapshot_json="${TMPDIR:-/tmp}/alttab-thumbnail-coverage-last.json"
alttab --selection-state > "$tmp_json"
cp "$tmp_json" "$snapshot_json"
alttab --hide >/dev/null || true
after_pids="$(pgrep -f '^/Applications/AltTab.app/Contents/MacOS/AltTab' | sort | tr '\n' ' ')"
if [ "$before_pids" != "$after_pids" ]; then
  printf '=== EVAL END MARKER: %s ===\n' "$MARKER" >> /tmp/alttab-run.log
  echo "FAIL: AltTab process set changed during thumbnail eval: before=[$before_pids] after=[$after_pids]" >&2
  exit 4
fi
if ! python3 -m json.tool "$tmp_json" >/dev/null 2>&1; then
  printf '=== EVAL END MARKER: %s ===\n' "$MARKER" >> /tmp/alttab-run.log
  echo "FAIL: no JSON selection-state response from AltTab CLI" >&2
  cat "$tmp_json" >&2 || true
  exit 5
fi

python3 - "$tmp_json" "$MIN_DISPLAYABLE" "$MIN_THUMBNAIL_RATIO" "$MAX_STALE_MS" "$CHECK_LIMIT" "$OWNER_REGEX" "$snapshot_json" "$VISIBLE_ONLY" <<'PY'
import json
import re
import sys
from collections import Counter

json_path = sys.argv[1]
min_displayable = int(sys.argv[2])
min_ratio = float(sys.argv[3])
max_stale_ms = float(sys.argv[4])
check_limit = int(sys.argv[5])
owner_regex = re.compile(sys.argv[6], re.I) if sys.argv[6] else None
snapshot_path = sys.argv[7]
with open(json_path) as f:
    data = json.load(f)
windows = [w for w in data.get("windows", []) if w.get("isDisplayable") and not w.get("isMinimized")]
all_windows = data.get("windows", [])
visible_ids = {int(wid) for wid in data.get("visibleThumbnailWindowIds", []) if wid is not None}
if sys.argv[8] == "1" and visible_ids:
    windows = [w for w in windows if w.get("id") in visible_ids]
if owner_regex:
    windows = [w for w in windows if owner_regex.search(w.get("appName") or "") or owner_regex.search(w.get("appBundleId") or "") or owner_regex.search(w.get("title") or "")]
eligible = windows[:max(min_displayable, min(check_limit, len(windows)))]
with_thumb = [w for w in eligible if w.get("hasThumbnail")]
fresh = [w for w in with_thumb if w.get("thumbnailAgeMs") is not None and w["thumbnailAgeMs"] <= max_stale_ms and w.get("thumbnailUpdateCount", 0) > 0]
ratio = (len(fresh) / len(eligible)) if eligible else 1.0
missing = [w for w in eligible if not w.get("hasThumbnail")]
stale = [w for w in with_thumb if w.get("thumbnailAgeMs") is None or w["thumbnailAgeMs"] > max_stale_ms or w.get("thumbnailUpdateCount", 0) <= 0]
scope = "visible" if sys.argv[8] == "1" and visible_ids else "list"
print(f"thumbnail-coverage scope={scope} visible_ids={len(visible_ids)} displayable={len(eligible)} fresh={len(fresh)} ratio={ratio:.2f} min_ratio={min_ratio:.2f} max_stale_ms={max_stale_ms:.0f} check_limit={check_limit}")
for label, rows in [("missing", missing[:12]), ("stale", stale[:12])]:
    for w in rows:
        print(f"{label}: wid={w.get('id')} app={w.get('appName')} title={(w.get('title') or '')[:80]} has={w.get('hasThumbnail')} age={w.get('thumbnailAgeMs')} updates={w.get('thumbnailUpdateCount')}")
if len(eligible) < min_displayable:
    hidden = [w for w in all_windows if not w.get("isDisplayable")]
    reason_counts = Counter(r for w in hidden for r in (w.get("displayHideReasons") or ["unknown"]))
    if reason_counts:
        print("hidden-reasons: " + ", ".join(f"{k}={v}" for k, v in reason_counts.most_common(8)))
    for w in hidden[:12]:
        print(f"hidden: wid={w.get('id')} app={w.get('appName')} title={(w.get('title') or '')[:80]} reasons={w.get('displayHideReasons')}")
    print(f"snapshot: {snapshot_path}")
    print(f"FAIL: only {len(eligible)} eligible displayable windows; need {min_displayable}", file=sys.stderr)
    sys.exit(2)
if ratio < min_ratio:
    print("FAIL: thumbnail coverage below threshold", file=sys.stderr)
    sys.exit(3)
PY

printf '=== EVAL END MARKER: %s ===\n' "$MARKER" >> /tmp/alttab-run.log
if ! python3 ai/eval-log-anomalies.py --marker "$MARKER" --end-marker "=== EVAL END MARKER: $MARKER ===" --strict > "$LOG_SCAN"; then
  cat "$LOG_SCAN"
  exit 6
fi
cat "$LOG_SCAN"
bash ai/eval-popup-storm-guard.sh thumbnail-post
