#!/bin/zsh
# Builds NothingX and assembles "build/Nothing X.app" (ad-hoc signed).
set -euo pipefail
cd "${0:A:h}"
swift build -c release --arch arm64 --arch x86_64
BIN_DIR=$(swift build -c release --arch arm64 --arch x86_64 --show-bin-path)
BIN="$BIN_DIR/NothingX"
APP="build/Nothing X.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp "$BIN" "$APP/Contents/MacOS/NothingX"
cp Resources/Info.plist "$APP/Contents/Info.plist"
mkdir -p "$APP/Contents/Resources"
cp -R Resources/*.lproj Resources/AppIcon.icns Resources/MenuBarIcon*.png "$APP/Contents/Resources/"
# Sparkle: embed the framework (ditto keeps its symlinks) and let the executable find it there.
# The XPC services are only needed by sandboxed apps; this one is not, so drop them.
mkdir -p "$APP/Contents/Frameworks"
ditto "$BIN_DIR/Sparkle.framework" "$APP/Contents/Frameworks/Sparkle.framework"
SPARKLE="$APP/Contents/Frameworks/Sparkle.framework"
rm -rf "$SPARKLE/XPCServices" "$SPARKLE/Versions/B/XPCServices"
if ! otool -l "$APP/Contents/MacOS/NothingX" | grep -q "@executable_path/../Frameworks"; then
    install_name_tool -add_rpath "@executable_path/../Frameworks" "$APP/Contents/MacOS/NothingX"
fi
# Signing: ad hoc by default. Set SIGN_IDENTITY to a keychain identity to keep the Bluetooth and audio
# permissions between rebuilds. HARDENED=1 enables the hardened runtime (required for notarization) and
# TIMESTAMP=1 adds a secure timestamp (needed for Developer ID releases; see release.sh).
# Nested code is signed inside-out (Sparkle's helpers, then the framework, then the app) with the same
# identity and options; the entitlements only apply to the app itself.
NESTED_ARGS=()
SIGN_ARGS=()
[[ -n "${HARDENED:-}" ]] && NESTED_ARGS+=(--options runtime) && SIGN_ARGS+=(--options runtime --entitlements Resources/NothingX.entitlements)
[[ -n "${TIMESTAMP:-}" ]] && NESTED_ARGS+=(--timestamp) && SIGN_ARGS+=(--timestamp)
for code in "$SPARKLE/Versions/B/Autoupdate" "$SPARKLE/Versions/B/Updater.app" "$SPARKLE"; do
    codesign -s "${SIGN_IDENTITY:--}" -f "${NESTED_ARGS[@]}" "$code"
done
codesign -s "${SIGN_IDENTITY:--}" -f "${SIGN_ARGS[@]}" "$APP"
echo "OK → $APP"
