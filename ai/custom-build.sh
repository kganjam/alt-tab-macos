#!/bin/bash
# Custom build wrapper that:
#   1. Substitutes BUILD_DATE_PLACEHOLDER in App.swift with the current timestamp
#   2. Builds Release with the Local Self-Signed cert
#   3. Restores App.swift
#   4. Installs to /Applications/AltTab.app (with backup)
#   5. Launches, redirecting logs to /tmp/alttab-run.log

set -e

cd "$(dirname "$0")/.."

BUILD_DATE="$(date '+%Y-%m-%d %H:%M')"
APP_SWIFT="src/ui/App.swift"

# Substitute placeholder with actual build date
sed -i.bak "s/BUILD_DATE_PLACEHOLDER/${BUILD_DATE}/" "$APP_SWIFT"

# Build
set +e
xcodebuild \
  -workspace alt-tab-macos.xcworkspace \
  -scheme Release \
  -configuration Release \
  -derivedDataPath DerivedData \
  CODE_SIGN_IDENTITY="Local Self-Signed" \
  OTHER_CODE_SIGN_FLAGS="--timestamp=none --deep --options runtime" \
  2>&1 | tee /tmp/alttab-release.log | grep -E "(error:|BUILD SUCCEEDED|BUILD FAILED)" | tail -5
BUILD_RC=${PIPESTATUS[0]}
set -e

# Restore App.swift regardless of build outcome
mv "${APP_SWIFT}.bak" "$APP_SWIFT"

if ! grep -q "BUILD SUCCEEDED" /tmp/alttab-release.log; then
    echo "BUILD FAILED — see /tmp/alttab-release.log"
    exit 1
fi

# Stop running, back up current, install, launch
pkill -f "/Applications/AltTab.app/Contents/MacOS/AltTab" 2>/dev/null || true
sleep 2
if [ -d /Applications/AltTab.app ]; then
    sudo rm -rf /Applications/AltTab.app.bak 2>/dev/null || true
    sudo mv /Applications/AltTab.app /Applications/AltTab.app.bak
fi
sudo cp -R DerivedData/Build/Products/Release/AltTab.app /Applications/AltTab.app

# Ensure diagnostics are on by default for this launch
defaults delete com.lwouis.alt-tab-macos diagnosticsEnabled 2>/dev/null || true

# Truncate the run log and launch
: > /tmp/alttab-run.log
/Applications/AltTab.app/Contents/MacOS/AltTab > /tmp/alttab-run.log 2>&1 &

sleep 3
PID=$(pgrep -f "/Applications/AltTab.app/Contents/MacOS/AltTab" | head -1)
echo "Custom AltTab running as pid $PID, version tag: CUSTOM BUILD ($BUILD_DATE)"
echo "Logs: tail -F /tmp/alttab-run.log | grep DIAG"
echo "Toggle off: defaults write com.lwouis.alt-tab-macos diagnosticsEnabled -bool false && kill $PID && open /Applications/AltTab.app"
