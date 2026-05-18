#!/usr/bin/env bash
set -euo pipefail

APP_BIN=${APP_BIN:-/tmp/alttab-eval-window-app}
if [ ! -x "$APP_BIN" ] || [ ai/eval-window-app.swift -nt "$APP_BIN" ]; then
  swiftc ai/eval-window-app.swift -o "$APP_BIN"
fi

pkill -f 'AltTabEval[AB].app/Contents/MacOS/AltTabEval' 2>/dev/null || true
pkill -f '/tmp/alttab-eval-window-app AltTabEval' 2>/dev/null || true
sleep 0.2

make_bundle() {
  local name=$1
  local color=$2
  local bundle=/tmp/${name}.app
  rm -rf "$bundle"
  mkdir -p "$bundle/Contents/MacOS"
  cp "$APP_BIN" "$bundle/Contents/MacOS/AltTabEval"
  cat > "$bundle/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key><string>AltTabEval</string>
  <key>CFBundleIdentifier</key><string>local.alttab.eval.${name}</string>
  <key>CFBundleName</key><string>${name}</string>
  <key>CFBundleDisplayName</key><string>${name}</string>
  <key>LSUIElement</key><false/>
  <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST
  open -na "$bundle" --args "$name" "$color"
}

make_bundle AltTabEvalA blue
make_bundle AltTabEvalB red
sleep 1.5
pgrep -laf 'AltTabEval[AB].app/Contents/MacOS/AltTabEval' || true
