#!/usr/bin/env bash
set -euo pipefail

LOG=${LOG:-/tmp/alttab-run.log}
MIN_SCREENS=${MIN_SCREENS:-2}
SINCE_LINES=${SINCE_LINES:-600}

TMP=${TMPDIR:-/tmp}/alttab-screens
cat > "$TMP.swift" <<'SWIFT'
import Cocoa

for (index, screen) in NSScreen.screens.enumerated() {
    let f = screen.frame
    print("\(index)\t\(Int(f.origin.x))\t\(Int(f.origin.y))\t\(Int(f.width))\t\(Int(f.height))")
}
SWIFT
swiftc "$TMP.swift" -o "$TMP.bin"
screens_output="$("$TMP.bin")"
count=$(printf '%s\n' "$screens_output" | sed '/^[[:space:]]*$/d' | wc -l | tr -d ' ')
printf 'screens=%s\n' "$count"
printf '%s\n' "$screens_output"
if [ "$count" -lt "$MIN_SCREENS" ]; then
  echo "SKIP: need at least $MIN_SCREENS screens for multi-screen click routing eval" >&2
  exit 0
fi

recent=$(tail -n "$SINCE_LINES" "$LOG" | grep 'DIAG CTAP' || true)
echo "$recent" | grep -E 'outsideUi-stale→hideUi-pass' >/dev/null || {
  echo "FAIL: no recent stale outside mouse-down pass-through log" >&2
  exit 1
}
echo "$recent" | grep -E 'outsideUi-after-pass' >/dev/null || {
  echo "FAIL: no recent matching outside mouse-up pass-through log" >&2
  exit 1
}
echo "PASS: recent click logs include outside down/up pass-through"
