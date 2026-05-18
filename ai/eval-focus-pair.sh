#!/usr/bin/env bash
set -euo pipefail

APP=${ALTTAB_APP:-/Applications/AltTab.app/Contents/MacOS/AltTab}
if [ -z "${ALTTAB_DYLIB_OVERRIDE:-}" ] && [ -f "$(pwd)/dev/AltTabCore.dylib" ]; then
  export ALTTAB_DYLIB_OVERRIDE="$(pwd)/dev/AltTabCore.dylib"
fi
SOURCE_APP=${1:-Terminal}
TARGET_APP=${2:-Safari}
SOURCE_INDEX=${SOURCE_INDEX:-0}
TARGET_INDEX=${TARGET_INDEX:-0}
SETTLE_MS=${SETTLE_MS:-700}
DURATION_MS=${DURATION_MS:-2600}
INTERVAL_MS=${INTERVAL_MS:-5}

pick_window() {
  local app=$1
  local index=$2
  "$APP" --detailed-list | jq -c --arg app "$app" --argjson index "$index" '[.windows[] | select((.appName | test($app; "i")) and (.isMinimized | not))][$index]'
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
"$APP" --focus="$source_wid" >/dev/null
sleep "$(python3 - <<PY
print($SETTLE_MS / 1000)
PY
)"
TARGET_WID=$target_wid DURATION_MS=$DURATION_MS INTERVAL_MS=$INTERVAL_MS bash ai/eval-focus-transition.sh "$TARGET_APP"
