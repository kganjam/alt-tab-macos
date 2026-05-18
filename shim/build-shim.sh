#!/bin/bash
# Compile the AltTab TCC anchor shim. Run this only when the shim's source
# (main.c / entitlements) changes. The output binary is checked in at
# shim/AltTab-shim and copied verbatim into the .app by ai/build.sh on
# every build, so its cdhash stays stable across rebuilds — that's the
# entire point of the shim approach.

set -e
cd "$(dirname "$0")"

OUT=AltTab-shim

# Universal binary so it runs on both x86_64 and arm64 hosts.
clang -O2 -arch arm64 -arch x86_64 \
    -Wall -Wextra -Wpedantic \
    -mmacosx-version-min=13.0 \
    -o "$OUT" main.c

# Sign with hardened runtime + the canonical AltTab entitlements (which
# already include disable-library-validation, required to dlopen the
# self-signed dylib). Identifier matches AltTab's bundle ID so TCC keys on
# (com.lwouis.alt-tab-macos, cert-leaf-hash) — the same DR as before the
# shim refactor, so existing TCC grants keep working.
codesign --force --sign "Local Self-Signed" \
    --options runtime --timestamp=none \
    --identifier com.lwouis.alt-tab-macos \
    --entitlements ../alt_tab_macos.entitlements \
    "$OUT"

echo "shim built: $(pwd)/$OUT"
codesign -dvvv "$OUT" 2>&1 | grep -E "Authority|Identifier|flags|CDHash" | head -6
echo ""
echo "Commit the binary so future rebuilds don't recompile it:"
echo "  git add $(pwd)/$OUT"
