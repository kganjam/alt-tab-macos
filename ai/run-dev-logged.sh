#!/usr/bin/env bash
set -euo pipefail

APP=${ALTTAB_APP:-/Applications/AltTab.app/Contents/MacOS/AltTab}
DYLIB=${ALTTAB_DYLIB_OVERRIDE:-$(pwd)/dev/AltTabCore.dylib}
LOG=${LOG:-/tmp/alttab-run.log}
LOG_LEVEL=${LOG_LEVEL:-perf}

if [ ! -f "$DYLIB" ]; then
  echo "Missing dev dylib: $DYLIB. Run: bash ai/build.sh dev" >&2
  exit 2
fi

pkill -TERM -f "$APP" >/dev/null 2>&1 || true
sleep 0.4
printf '=== DEV LOGGED RUN: %s — dylib=%s ===\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$DYLIB" | tee -a "$LOG"
export ALTTAB_DYLIB_OVERRIDE="$DYLIB"
exec "$APP" "--logs=$LOG_LEVEL" 2>&1 | tee -a "$LOG"
