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
# Ad-hoc by default (used for releases). For local dev builds, set SIGN_IDENTITY to a keychain identity so
# macOS keeps the Bluetooth and audio permissions between rebuilds.
codesign -s "${SIGN_IDENTITY:--}" -f --deep "$APP"
echo "OK → $APP"
