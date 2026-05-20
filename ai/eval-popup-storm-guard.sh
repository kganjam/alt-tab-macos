#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
GUARD_BIN=${POPUP_STORM_GUARD_BIN:-/tmp/alttab-popup-storm-guard}
MAX_WINDOWS=${POPUP_STORM_MAX_USER_NOTIFICATION_WINDOWS:-1}
TOP_COUNT=${POPUP_STORM_TOP_COUNT:-8}
CONTEXT=${POPUP_STORM_CONTEXT:-${1:-}}
MARKER=${MARKER:-}
LOG=${ALTTAB_LOG:-/tmp/alttab-run.log}

if [ "${POPUP_STORM_GUARD:-1}" = "0" ]; then
  exit 0
fi
if [ ! -x "$GUARD_BIN" ] || [ "$SCRIPT_DIR/popup-storm-guard.swift" -nt "$GUARD_BIN" ]; then
  swiftc "$SCRIPT_DIR/popup-storm-guard.swift" -o "$GUARD_BIN"
fi
"$GUARD_BIN" --max-user-notification-windows "$MAX_WINDOWS" --top-count "$TOP_COUNT" --context "$CONTEXT" --marker "$MARKER" --log "$LOG"
