#!/bin/bash
# Unified build/install/dev-iterate script for AltTab.
#
# Modes:
#   compile  Debug build to DerivedData. Just verifies the code compiles.
#            No signing, no install, no run. Fast (~30s incremental).
#
#   dev      Release build of AltTabCore.dylib only, signed and dropped
#            at dev/AltTabCore.dylib. Launches the *installed* shim
#            binary at /Applications/AltTab.app/Contents/MacOS/AltTab
#            with $ALTTAB_DYLIB_OVERRIDE pointing at dev/AltTabCore.dylib.
#            The installed bundle is NEVER modified, so its code-signing
#            seal stays intact and TCC permissions persist. Use this for
#            every code iteration once the bundle is installed.
#
#   install  Full bundle install. Builds Release as a dylib, swaps the
#            shim Mach-O into Contents/MacOS/AltTab, signs everything
#            bottom-up, and atomically replaces /Applications/AltTab.app
#            via ditto+mv. Triggers a TCC re-grant prompt every time
#            (macOS bundle-replaced-at-known-path → tccd revalidates).
#            Use only when shim/main.c, Pods, framework deps, or
#            entitlements change — rare.
#
# See memory project_alttab_tcc_seal.md for why dev-mode preserves TCC
# and install-mode doesn't.

set -e
cd "$(dirname "$0")/.."

MODE="${1:-}"
case "$MODE" in
    compile|dev|install) ;;
    *) echo "usage: $0 {compile|dev|install}" >&2; exit 2 ;;
esac

# === COMPILE MODE: Debug build, that's it. ===
# Critically, REMOVE the Debug AltTab.app + unregister from LaunchServices
# after the build. LaunchServices auto-indexes any .app under /Users that
# matches a known bundle ID; a duplicate AltTab.app (same DR, different
# cdhash than the installed one) fragments TCC and triggers re-prompts on
# every launch of the installed copy. Just verify the build then nuke the
# bundle artifact — we only need to know the source compiles.
if [ "$MODE" = "compile" ]; then
    xcodebuild \
        -workspace alt-tab-macos.xcworkspace \
        -scheme Debug \
        -configuration Debug \
        -derivedDataPath DerivedData \
        CODE_SIGNING_ALLOWED=NO \
        CODE_SIGNING_REQUIRED=NO \
        CODE_SIGN_IDENTITY="" \
        2>&1 | tail -30 | grep -E "(error:|warning:|BUILD SUCCEEDED|BUILD FAILED)" | tail -10
    rc=${PIPESTATUS[0]}
    DEBUG_APP="DerivedData/Build/Products/Debug/AltTab.app"
    if [ -d "$DEBUG_APP" ]; then
        LSREG=/System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks/LaunchServices.framework/Versions/A/Support/lsregister
        "$LSREG" -u "$(pwd)/$DEBUG_APP" 2>/dev/null || true
        rm -rf "$DEBUG_APP"
    fi
    exit $rc
fi

# === DEV / INSTALL: shared prep + Release-as-dylib build ===
APP_SWIFT="src/ui/App.swift"
SIGN_ID="Local Self-Signed"
BUILD_DATE="$(date '+%Y-%m-%d %H:%M')"
if [ "$MODE" = "dev" ]; then BUILD_DATE="$BUILD_DATE dev"; fi

sed -i.bak "s/BUILD_DATE_PLACEHOLDER/${BUILD_DATE}/" "$APP_SWIFT"
trap 'mv "${APP_SWIFT}.bak" "$APP_SWIFT" 2>/dev/null || true' EXIT

set +e
xcodebuild \
    -workspace alt-tab-macos.xcworkspace \
    -scheme Release \
    -configuration Release \
    -derivedDataPath DerivedData \
    MACH_O_TYPE=mh_dylib \
    STRIP_INSTALLED_PRODUCT=NO \
    COPY_PHASE_STRIP=NO \
    CODE_SIGN_IDENTITY="$SIGN_ID" \
    OTHER_CODE_SIGN_FLAGS="--timestamp=none --deep --options runtime" \
    2>&1 | tee /tmp/alttab-release.log | grep -E "(error:|BUILD SUCCEEDED|BUILD FAILED)" | tail -5
set -e

if ! grep -q "BUILD SUCCEEDED" /tmp/alttab-release.log; then
    echo "BUILD FAILED — see /tmp/alttab-release.log" >&2
    exit 1
fi

APP_DIR=DerivedData/Build/Products/Release/AltTab.app

# === STOP RUNNING INSTANCE ===
osascript -e 'tell application id "com.lwouis.alt-tab-macos" to quit' 2>/dev/null || true
pkill -f 'AltTab\.app/Contents/MacOS/AltTab' 2>/dev/null || true
sleep 1
pkill -9 -f 'AltTab\.app/Contents/MacOS/AltTab' 2>/dev/null || true

# NOTE: defensive helper-kill removed — it caused an extra Coherence flash
# on every dev-build. AltTab's startIfNeeded now handles all cases:
#   - Script unchanged + helper PING-healthy → re-use, 0 flashes.
#   - Script changed                         → kill + relaunch (intentional).
#   - PING failed (orphan after crash)       → kill + relaunch.
# Graceful AltTab quit kills the helper via socket EXIT (no flash).

# === DEV MODE: rebuild dylib, override env-var launch ===
if [ "$MODE" = "dev" ]; then
    DEST=/Applications/AltTab.app
    if [ ! -f "$DEST/Contents/MacOS/AltTab" ]; then
        echo "ERROR: $DEST not installed. Run '$0 install' first." >&2
        exit 1
    fi
    DEV_DYLIB="$(pwd)/dev/AltTabCore.dylib"
    mkdir -p "$(dirname "$DEV_DYLIB")"
    mv "$APP_DIR/Contents/MacOS/AltTab" "$DEV_DYLIB"
    codesign --force --sign "$SIGN_ID" --options runtime --timestamp=none "$DEV_DYLIB"
    echo "  dev dylib cdhash: $(codesign -dvvv "$DEV_DYLIB" 2>&1 | awk -F= '/^CDHash=/{print $2; exit}')"
    # The dylib has been extracted; the leftover .app shell in DerivedData is a
    # broken bundle (no main Mach-O) that Spotlight/LaunchServices still indexes,
    # cluttering search with a phantom AltTab. Remove it (install mode does the
    # same via `rm -rf "$APP_DIR"`). The next build relinks it as needed.
    LSREG=/System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks/LaunchServices.framework/Versions/A/Support/lsregister
    "$LSREG" -u "$APP_DIR" 2>/dev/null || true
    rm -rf "$APP_DIR"
    # LaunchServices owns the long-running process. A direct background exec
    # from this script can receive SIGHUP/terminate when the wrapper exits,
    # leaving AltTab dead after a successful dev build. Use launchctl to pass
    # the override env through LaunchServices without modifying the installed
    # bundle, preserving TCC grants.
    # AltTab's Logger.swift now writes its own per-process log to
    # /tmp/alttab/<YYYYMMDD-HHMMSS>.<pid>.log (latest via /tmp/alttab/latest.log).
    # We deliberately do NOT pass --stdout/--stderr here — that was truncating
    # the prior shared /tmp/alttab-run.log on every dev rebuild.
    launchctl setenv ALTTAB_DYLIB_OVERRIDE "$DEV_DYLIB"
    open -na "$DEST"
    sleep 3
    PID=$(pgrep -f 'AltTab\.app/Contents/MacOS/AltTab' | head -1)
    LOG_PATH=$(readlink /tmp/alttab/latest.log 2>/dev/null)
    echo "Dev AltTab pid $PID, dylib: $DEV_DYLIB"
    echo "Log file: ${LOG_PATH:-/tmp/alttab/latest.log}"
    MONITOR_SECONDS="${ALTTAB_POST_BUILD_MONITOR_SECONDS:-5}"
    if [ "$MONITOR_SECONDS" != "0" ]; then
        echo "=== monitoring runtime anomalies for ${MONITOR_SECONDS}s ==="
        if ! python3 ai/monitor-runtime-anomalies.py --duration "$MONITOR_SECONDS"; then
            echo "POST-BUILD RUNTIME ANOMALIES DETECTED — inspect ${LOG_PATH:-/tmp/alttab/latest.log}" >&2
            exit 86
        fi
    fi
    echo "  python3 ai/monitor-runtime-anomalies.py --duration 60"
    exit 0
fi

# === INSTALL MODE: full bundle, bottom-up sign, atomic install ===
SHIM_BIN="$(pwd)/shim/AltTab-shim"
ENTITLEMENTS="$(pwd)/alt_tab_macos.entitlements"
if [ ! -f "$SHIM_BIN" ]; then
    echo "FATAL: shim binary not found at $SHIM_BIN — run shim/build-shim.sh first" >&2
    exit 1
fi

# Shim swap: place dylib + shim in their final positions
mkdir -p "$APP_DIR/Contents/Frameworks"
mv "$APP_DIR/Contents/MacOS/AltTab" "$APP_DIR/Contents/Frameworks/AltTabCore.dylib"
cp "$SHIM_BIN" "$APP_DIR/Contents/MacOS/AltTab"

# Pods umbrella — Xcode skips embedding it when the product is a dylib.
PODS_FRAMEWORK_SRC=DerivedData/Build/Products/Release/Pods_alt_tab_macos.framework
if [ -d "$PODS_FRAMEWORK_SRC" ]; then
    rm -rf "$APP_DIR/Contents/Frameworks/Pods_alt_tab_macos.framework"
    cp -R "$PODS_FRAMEWORK_SRC" "$APP_DIR/Contents/Frameworks/"
fi

# Bottom-up sign: nested items first, then the bundle. The bundle sign
# regenerates _CodeSignature/CodeResources so the seal is consistent.
echo ""
echo "=== signing nested items ==="
for item in "$APP_DIR/Contents/Frameworks/"*.dylib \
            "$APP_DIR/Contents/Frameworks/"*.framework; do
    [ -e "$item" ] || continue
    codesign --force --sign "$SIGN_ID" --options runtime --timestamp=none "$item" 2>&1 | tail -1
done
echo ""
echo "=== signing bundle ==="
codesign --force --deep --sign "$SIGN_ID" --options runtime --timestamp=none \
    --entitlements "$ENTITLEMENTS" "$APP_DIR" 2>&1 | tail -3

echo ""
echo "=== verify --deep --strict ==="
if ! codesign --verify --deep --strict "$APP_DIR"; then
    echo "FATAL: bundle signature verification failed — refusing to install" >&2
    exit 1
fi
echo "  OK: bundle seal verified"
echo "  shim cdhash: $(codesign -dvvv "$APP_DIR/Contents/MacOS/AltTab" 2>&1 | awk -F= '/^CDHash=/{print $2; exit}')"
echo "  dylib cdhash: $(codesign -dvvv "$APP_DIR/Contents/Frameworks/AltTabCore.dylib" 2>&1 | awk -F= '/^CDHash=/{print $2; exit}')"
echo "  bundle DR: $(codesign -d -r- "$APP_DIR" 2>&1 | awk '/designated/{$1=""; print substr($0,2)}')"

# Atomic install via sibling .new + mv. Quinn explicitly warns against
# overwriting individual files inside a live bundle (kernel vnode cache
# corruption) — Apple DevForums #781548.
DEST=/Applications/AltTab.app
NEW=/Applications/AltTab.app.new
sudo rm -rf "$NEW"
sudo ditto "$APP_DIR" "$NEW"
if [ -d "$DEST" ]; then
    sudo rm -rf "$DEST.old"
    sudo mv "$DEST" "$DEST.old"
fi
sudo mv "$NEW" "$DEST"
sudo rm -rf "$DEST.old"

# Stale DerivedData copy — remove so LaunchServices doesn't ever attribute
# a process to that path.
rm -rf "$APP_DIR"

LSREG=/System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks/LaunchServices.framework/Versions/A/Support/lsregister
"$LSREG" "$DEST" 2>/dev/null || true

# Best-effort user-TCC pre-grant. System TCC needs SIP partial-disable
# (we don't do that). Failures are non-fatal — macOS prompts.
bash "$(dirname "$0")/tcc.sh" grant 2>&1 | sed 's/^/  [tcc] /' || true

defaults delete com.lwouis.alt-tab-macos diagnosticsEnabled 2>/dev/null || true

# AltTab's Logger.swift writes its own per-process log to
# /tmp/alttab/<YYYYMMDD-HHMMSS>.<pid>.log (latest via /tmp/alttab/latest.log
# and the back-compat /tmp/alttab-run.log symlink). Do NOT pass
# --stdout/--stderr here — that was truncating the log on every rebuild.
open -na "$DEST"
sleep 3
PID=$(pgrep -f 'AltTab\.app/Contents/MacOS/AltTab' | head -1)
RUNNING_PATH=$(ps -p "$PID" -o command= 2>/dev/null | head -1)
LOG_PATH=$(readlink /tmp/alttab/latest.log 2>/dev/null)
echo ""
echo "AltTab pid $PID, version: CUSTOM BUILD ($BUILD_DATE)"
echo "Running from: $RUNNING_PATH"
echo "Log file: ${LOG_PATH:-/tmp/alttab/latest.log}"
case "$RUNNING_PATH" in
    /Applications/AltTab.app/*) ;;
    *) echo "WARNING: AltTab is running from an unexpected path. Permissions may not apply." ;;
esac
MONITOR_SECONDS="${ALTTAB_POST_BUILD_MONITOR_SECONDS:-5}"
if [ "$MONITOR_SECONDS" != "0" ]; then
    echo "=== monitoring runtime anomalies for ${MONITOR_SECONDS}s ==="
    if ! python3 ai/monitor-runtime-anomalies.py --duration "$MONITOR_SECONDS"; then
        echo "POST-BUILD RUNTIME ANOMALIES DETECTED — inspect ${LOG_PATH:-/tmp/alttab/latest.log}" >&2
        exit 86
    fi
fi
echo "  python3 ai/monitor-runtime-anomalies.py --duration 60"
echo "Next iterations: bash ai/build.sh dev    # no install, no TCC churn"
