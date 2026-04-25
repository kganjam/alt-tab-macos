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

# Stop running — kill ANY AltTab process regardless of path. The previous
# variant only matched /Applications/... and would leave a stale instance
# running from DerivedData/Release/AltTab.app (since `cp` is launched after
# pkill). When the new /Applications copy starts, macOS treats it as a
# duplicate bundle, the new instance exits, and the old DerivedData
# instance keeps running. tccd then attributes the running pid to the
# DerivedData path, which can cause permission prompts to keep reappearing
# even though System Settings shows /Applications/AltTab.app as granted.
osascript -e 'tell application id "com.lwouis.alt-tab-macos" to quit' 2>/dev/null || true
pkill -f 'AltTab\.app/Contents/MacOS/AltTab' 2>/dev/null || true
sleep 2
# Force-kill anything that resisted SIGTERM
pkill -9 -f 'AltTab\.app/Contents/MacOS/AltTab' 2>/dev/null || true

if [ -d /Applications/AltTab.app ]; then
    sudo rm -rf /Applications/AltTab.app.bak 2>/dev/null || true
    sudo mv /Applications/AltTab.app /Applications/AltTab.app.bak
fi
sudo cp -R DerivedData/Build/Products/Release/AltTab.app /Applications/AltTab.app

# Remove the DerivedData copies so Launch Services and TCC can't attribute
# a process to those paths. Xcode will rebuild them on next compile, but
# they should never be the *running* instance.
rm -rf DerivedData/Build/Products/Release/AltTab.app
rm -rf DerivedData/Build/Products/Debug/AltTab.app 2>/dev/null || true

# Reset Launch Services so /Applications/AltTab.app is the only registered
# AltTab bundle. Without this, `open -n` and process-attribution can pick
# stale registrations (Debug build, .bak, Trash copies, etc.).
LSREG=/System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks/LaunchServices.framework/Versions/A/Support/lsregister
"$LSREG" -kill -r -domain local -domain system -domain user 2>/dev/null || true
"$LSREG" /Applications/AltTab.app 2>/dev/null || true

# Best-effort: pre-grant TCC entries so the rebuild doesn't re-prompt for
# permissions. Requires the invoking shell to have Full Disk Access (and
# SIP at least partially disabled to write the system DB). Failures are
# non-fatal — macOS will fall back to its prompt.
bash "$(dirname "$0")/tcc.sh" grant 2>&1 | sed 's/^/  [tcc] /' || true

# Ensure diagnostics are on by default for this launch
defaults delete com.lwouis.alt-tab-macos diagnosticsEnabled 2>/dev/null || true

# Append to run log (don't truncate) with build marker
echo "=== NEW BUILD: $BUILD_DATE (pid $$) ===" >> /tmp/alttab-run.log
# Launch via Launch Services so process attribution lands on /Applications.
# Direct binary exec works too, but `open -na` is safer once we've cleaned
# up the LS registry above — it ensures the bundle path resolves to the
# /Applications copy and not a stale DerivedData entry.
open -na /Applications/AltTab.app --stdout /tmp/alttab-run.log --stderr /tmp/alttab-run.log

sleep 3
PID=$(pgrep -f 'AltTab\.app/Contents/MacOS/AltTab' | head -1)
RUNNING_PATH=$(ps -p "$PID" -o command= 2>/dev/null | head -1)
echo "Custom AltTab running as pid $PID, version tag: CUSTOM BUILD ($BUILD_DATE)"
echo "Running from: $RUNNING_PATH"
case "$RUNNING_PATH" in
    /Applications/AltTab.app/*) ;; # ok
    *) echo "WARNING: AltTab is running from an unexpected path. Permissions may not apply." ;;
esac
echo "Logs: tail -F /tmp/alttab-run.log | grep DIAG"
echo "Toggle off: defaults write com.lwouis.alt-tab-macos diagnosticsEnabled -bool false && kill $PID && open /Applications/AltTab.app"
