#!/usr/bin/env bash
set -euo pipefail

WATCH_APP=${1:-Safari}
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
SAMPLER=${SAMPLER:-/tmp/alttab-z-order-sampler}
OUT=${OUT:-/tmp/alttab-restart-zorder-$(date +%Y%m%d-%H%M%S).jsonl}
DEV_DYLIB=${ALTTAB_DYLIB_OVERRIDE:-$(pwd)/dev/AltTabCore.dylib}

if [ ! -x "$SAMPLER" ] || [ ai/z-order-sampler.swift -nt "$SAMPLER" ]; then
  swiftc ai/z-order-sampler.swift -o "$SAMPLER"
fi

target_json=$(alttab --detailed-list | jq -c --arg app "$WATCH_APP" 'first(.windows[] | select(.appName | test($app; "i")))')
if [ -z "$target_json" ] || [ "$target_json" = "null" ]; then
  echo "No watch window matching app pattern: $WATCH_APP" >&2
  exit 2
fi
wid=$(jq -r '.id' <<<"$target_json")

"$SAMPLER" --target-wid "$wid" --duration-ms 120 --interval-ms 20 > "$OUT.before"
pkill -x AltTab || true
sleep 0.8
launchctl setenv ALTTAB_DYLIB_OVERRIDE "$DEV_DYLIB"
open -na /Applications/AltTab.app --stdout /tmp/alttab-run.log --stderr /tmp/alttab-run.log --args --logs=warning
sleep 0.8
"$SAMPLER" --target-wid "$wid" --duration-ms 2500 --interval-ms 10 > "$OUT.after"
cat "$OUT.before" "$OUT.after" > "$OUT"

python3 - "$OUT.before" "$OUT.after" "$WATCH_APP" "$wid" <<'PY'
import json, sys
before_path, after_path, watch, wid = sys.argv[1], sys.argv[2], sys.argv[3], int(sys.argv[4])
def read(path):
    rows = []
    with open(path) as f:
        for line in f:
            try: rows.append(json.loads(line))
            except json.JSONDecodeError: pass
    return rows
before, after = read(before_path), read(after_path)
before_last = before[-1] if before else {}
after_rows = after
def count_watch_top16(row):
    return sum(1 for owner in row.get("top_owners", []) if watch.lower() in owner.lower())
def target_z(row):
    return row.get("target_z")
watch_top16_counts = [count_watch_top16(r) for r in after_rows]
target_zs = [target_z(r) for r in after_rows if target_z(r) is not None]
top_changes, last = [], None
for r in after_rows:
    cur = tuple(zip(r.get("top_wids", [])[:8], r.get("top_owners", [])[:8]))
    if cur != last:
        top_changes.append((round(r.get("t_ms", 0), 1), cur))
        last = cur
print(f"watch_app={watch!r} watch_wid={wid}")
print(f"before_top8={list(zip(before_last.get('top_wids', [])[:8], before_last.get('top_owners', [])[:8]))}")
print(f"after_watch_count_top16_max={max(watch_top16_counts, default=0)} after_watch_count_top16_last={watch_top16_counts[-1] if watch_top16_counts else 0}")
print(f"after_target_z_min={min(target_zs) if target_zs else 'missing'} after_target_z_last={target_zs[-1] if target_zs else 'missing'}")
print(f"sample_file={after_path}")
print("after_top_changes:")
for t, cur in top_changes[:16]:
    print(f"  {t} {list(cur)}")
if len(top_changes) > 16:
    print(f"  ... {len(top_changes) - 16} more")
PY
