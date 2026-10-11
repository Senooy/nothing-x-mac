#!/bin/zsh
# Builds NothingX and assembles "build/Nothing X.app" (ad-hoc signed).
set -euo pipefail
cd "${0:A:h}"
swift build -c release
BIN=$(swift build -c release --show-bin-path)/NothingX
APP="build/Nothing X.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp "$BIN" "$APP/Contents/MacOS/NothingX"
cp Resources/Info.plist "$APP/Contents/Info.plist"
mkdir -p "$APP/Contents/Resources"
cp -R Resources/*.lproj "$APP/Contents/Resources/"
codesign -s - -f --deep "$APP"
echo "OK → $APP"
