#!/usr/bin/env bash
set -euo pipefail

APP=${ALTTAB_APP:-/Applications/AltTab.app/Contents/MacOS/AltTab}
if [ -z "${ALTTAB_DYLIB_OVERRIDE:-}" ] && [ -f "$(pwd)/dev/AltTabCore.dylib" ]; then
  export ALTTAB_DYLIB_OVERRIDE="$(pwd)/dev/AltTabCore.dylib"
fi
OWNER_REGEX=${OWNER_REGEX:-"Parallels Desktop"}
TITLE_REGEX=${TITLE_REGEX:-"Windows 11"}
REQUIRE=${REQUIRE:-0}
SHORTCUT_INDEX=${SHORTCUT_INDEX:-0}
SHOW_WAIT_MS=${SHOW_WAIT_MS:-200}
ONLY_ALT_TAB_DISPLAYABLE=${ONLY_ALT_TAB_DISPLAYABLE:-1}
TMP=${TMPDIR:-/tmp}/alttab-visible-windows

cat > "$TMP.swift" <<'SWIFT'
import CoreGraphics
import Foundation

let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
let rows = (CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]]) ?? []
for row in rows {
    guard ((row[kCGWindowLayer as String] as? Int) ?? 0) == 0 else { continue }
    guard ((row[kCGWindowAlpha as String] as? Double) ?? 1.0) >= 0.1 else { continue }
    guard let wid = row[kCGWindowNumber as String] as? Int,
          let pid = row[kCGWindowOwnerPID as String] as? Int,
          let owner = row[kCGWindowOwnerName as String] as? String,
          let bounds = row[kCGWindowBounds as String] as? [String: Any],
          let width = bounds["Width"] as? Double,
          let height = bounds["Height"] as? Double,
          width >= 40,
          height >= 40 else { continue }
    let title = row[kCGWindowName as String] as? String ?? ""
    let safeOwner = owner.replacingOccurrences(of: "\t", with: " ")
    let safeTitle = title.replacingOccurrences(of: "\t", with: " ")
    print("\(wid)\t\(pid)\t\(safeOwner)\t\(safeTitle)\t\(Int(width))\t\(Int(height))")
}
SWIFT
swiftc "$TMP.swift" -o "$TMP.bin"
"$TMP.bin" > "$TMP.tsv"
"$APP" --show="$SHORTCUT_INDEX" 2>/dev/null | sed -n '/^[[:space:]]*[{[]/,$p' >/dev/null || true
sleep "$(python3 - <<PY
print(max(0, int("$SHOW_WAIT_MS")) / 1000)
PY
)"
"$APP" --detailed-list 2>/dev/null | sed -n '/^[[:space:]]*[{[]/,$p' > "$TMP.json"
"$APP" --hide 2>/dev/null | sed -n '/^[[:space:]]*[{[]/,$p' >/dev/null || true
python3 - "$TMP.tsv" "$TMP.json" "$OWNER_REGEX" "$TITLE_REGEX" "$REQUIRE" "$ONLY_ALT_TAB_DISPLAYABLE" <<'PY'
import json
import re
import sys
from pathlib import Path

tsv, json_path, owner_re, title_re, require, only_displayable = sys.argv[1:]
owner_pat = re.compile(owner_re, re.I)
title_pat = re.compile(title_re, re.I)
visible = []
for line in Path(tsv).read_text().splitlines():
    parts = line.split("\t")
    if len(parts) < 6:
        continue
    wid, pid, owner, title, width, height = parts[:6]
    if owner_pat.search(owner) and title_pat.search(title):
        visible.append((int(wid), int(pid), owner, title, width, height))
data = json.loads(Path(json_path).read_text() or '{"windows":[]}')
by_id = {int(w["id"]): w for w in data.get("windows", []) if w.get("id") is not None}
if only_displayable == "1":
    displayable_ids = {wid for wid, row in by_id.items() if row.get("isDisplayable", True)}
    visible = [row for row in visible if row[0] in displayable_ids]
failures = []
for wid, pid, owner, title, width, height in visible:
    row = by_id.get(wid)
    if row is None:
        failures.append(f"missing wid={wid} pid={pid} owner={owner} title={title}")
        continue
    if not row.get("isDisplayable", True):
        failures.append(f"not-displayable wid={wid} pid={pid} owner={owner} title={title} shouldShow={row.get('shouldShowTheUser')} reasons={row.get('displayHideReasons')}")
if not visible:
    status = "FAIL" if require == "1" else "SKIP"
    print(f"{status} no visible WindowServer windows matched owner={owner_re!r} title={title_re!r}")
    sys.exit(1 if require == "1" else 0)
if failures:
    print(f"FAIL window coverage owner={owner_re!r} title={title_re!r} visible={len(visible)}")
    for failure in failures:
        print(f"  {failure}")
    sys.exit(1)
print(f"PASS window coverage owner={owner_re!r} title={title_re!r} visible={len(visible)}")
for wid, pid, owner, title, width, height in visible[:8]:
    print(f"  wid={wid} pid={pid} owner={owner} title={title} size={width}x{height}")
PY
