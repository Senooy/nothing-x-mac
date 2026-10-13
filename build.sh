#!/bin/zsh
# Builds NothingX and assembles "build/Nothing X.app" (ad-hoc signed).
set -euo pipefail
cd "${0:A:h}"
swift build -c release --arch arm64 --arch x86_64
BIN=$(swift build -c release --arch arm64 --arch x86_64 --show-bin-path)/NothingX
APP="build/Nothing X.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp "$BIN" "$APP/Contents/MacOS/NothingX"
cp Resources/Info.plist "$APP/Contents/Info.plist"
mkdir -p "$APP/Contents/Resources"
cp -R Resources/*.lproj Resources/AppIcon.icns Resources/MenuBarIcon*.png "$APP/Contents/Resources/"
# Signing: ad hoc by default. Set SIGN_IDENTITY to a keychain identity to keep the Bluetooth and audio
# permissions between rebuilds. HARDENED=1 enables the hardened runtime (required for notarization) and
# TIMESTAMP=1 adds a secure timestamp (needed for Developer ID releases; see release.sh).
SIGN_ARGS=()
[[ -n "${HARDENED:-}" ]] && SIGN_ARGS+=(--options runtime --entitlements Resources/NothingX.entitlements)
[[ -n "${TIMESTAMP:-}" ]] && SIGN_ARGS+=(--timestamp)
codesign -s "${SIGN_IDENTITY:--}" -f --deep "${SIGN_ARGS[@]}" "$APP"
echo "OK → $APP"
