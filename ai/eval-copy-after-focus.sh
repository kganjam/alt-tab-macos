#!/usr/bin/env bash
set -euo pipefail

APP=${ALTTAB_APP:-/Applications/AltTab.app/Contents/MacOS/AltTab}
if [ -z "${ALTTAB_DYLIB_OVERRIDE:-}" ] && [ -f "$(pwd)/dev/AltTabCore.dylib" ]; then
  export ALTTAB_DYLIB_OVERRIDE="$(pwd)/dev/AltTabCore.dylib"
fi
TARGET_APP=${1:-Safari}
DELAY=${DELAY:-1.0}
POSTER=${POSTER:-/tmp/alttab-post-key-combo}

if [ ! -x "$POSTER" ] || [ ai/post-key-combo.swift -nt "$POSTER" ]; then
  swiftc ai/post-key-combo.swift -o "$POSTER"
fi

target_json=$("$APP" --detailed-list | jq -c --arg app "$TARGET_APP" 'first(.windows[] | select(.appName | test($app; "i")))')
if [ -z "$target_json" ]; then
  echo "No target window matching app pattern: $TARGET_APP" >&2
  exit 2
fi

wid=$(jq -r '.id' <<<"$target_json")
"$POSTER" >/dev/null
"$APP" --focus="$wid" >/dev/null
sleep "$DELAY"
front=$(osascript -e 'tell application "System Events" to get name of first application process whose frontmost is true' 2>/dev/null || true)
expected=""
if [ "$front" = "Safari" ]; then
  expected=$(osascript -e 'tell application "Safari" to return URL of current tab of front window')
fi
printf 'ALT_TAB_COPY_SENTINEL' | pbcopy
"$POSTER" 37 8 >/dev/null
sleep 0.4
actual=$(pbpaste)
"$POSTER" >/dev/null
match=no
[ -n "$expected" ] && [ "$expected" = "$actual" ] && match=yes
if [ "$match" = no ] && [ -n "$expected" ] && [ "${expected%/}" = "$actual" ]; then
  match=yes
fi
printf 'target_app=%s wid=%s front=%s expected_bytes=%s actual_bytes=%s match=%s\n' "$TARGET_APP" "$wid" "$front" "$(printf %s "$expected" | wc -c | tr -d ' ')" "$(printf %s "$actual" | wc -c | tr -d ' ')" "$match"
[ "$match" = yes ]
