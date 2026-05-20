#!/usr/bin/env bash
set -euo pipefail

APP=${ALTTAB_APP:-/Applications/AltTab.app/Contents/MacOS/AltTab}
if [ -z "${ALTTAB_DYLIB_OVERRIDE:-}" ] && [ -f "$(pwd)/dev/AltTabCore.dylib" ]; then
  export ALTTAB_DYLIB_OVERRIDE="$(pwd)/dev/AltTabCore.dylib"
fi
POSTER=${POSTER:-/tmp/alttab-post-cmd-backtick-hold}
HOLD_MS=${HOLD_MS:-1200}
PROBE_MS=${PROBE_MS:-750}
LOG=${LOG:-/tmp/alttab-run.log}

if [ "${ALLOW_SYNTHETIC_HOTKEY_TESTS:-0}" != "1" ]; then
  echo "Refusing to post global Cmd+\` hotkeys. Set ALLOW_SYNTHETIC_HOTKEY_TESTS=1 on an isolated test desktop." >&2
  exit 2
fi

bash ai/eval-user-idle-guard.sh "cmd-backtick-gallery"

alttab() {
  local out status
  set +e
  out=$("$APP" "$@" 2>&1)
  status=$?
  set -e
  printf '%s\n' "$out" | sed -n '/^[[:space:]]*[{[]/,$p'
  return "$status"
}

if [ ! -x "$POSTER" ] || [ ai/post-cmd-backtick-hold.swift -nt "$POSTER" ]; then
  swiftc ai/post-cmd-backtick-hold.swift -o "$POSTER"
fi

marker="CMD_BACKTICK_EVAL_$(date +%s%N)"
echo "$marker" >> "$LOG"
"$POSTER" "$HOLD_MS" &
poster_pid=$!
sleep "$(python3 - <<PY
print(max(0, int("$PROBE_MS")) / 1000)
PY
)"
tmp_json="$(mktemp "${TMPDIR:-/tmp}/alttab-cmd-backtick-state.XXXXXX")"
alttab --selection-state > "$tmp_json"
wait "$poster_pid" || true
alttab --hide >/dev/null || true

python3 - "$tmp_json" <<'PY'
import json
import sys

data = json.load(open(sys.argv[1]))
if not data.get("appIsBeingUsed"):
    print("FAIL: Cmd+` did not open/hold the AltTab gallery")
    sys.exit(1)
print(f"PASS: Cmd+` opened gallery selectedIndex={data.get('selectedIndex')} windows={len(data.get('windows', []))}")
PY

if ! awk "/$marker/{seen=1} seen && /showPanel/" "$LOG" | grep -q .; then
  echo "FAIL: Cmd+\` did not log showPanel while held" >&2
  exit 1
fi
if awk "/$marker/{seen=1} seen && /not registering nextWindowShortcut2/" "$LOG" | grep -q .; then
  echo "FAIL: nextWindowShortcut2 was protected instead of registered" >&2
  exit 1
fi
