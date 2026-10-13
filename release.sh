#!/bin/zsh
# Builds, signs (Developer ID + hardened runtime), packages, notarizes and staples the DMG.
#
# One-time setup (needs your Apple Developer account, do it yourself):
#   1. Create a "Developer ID Application" certificate (Xcode > Settings > Accounts > Manage Certificates).
#   2. Store notarization credentials in the keychain:
#        xcrun notarytool store-credentials "nothing-x-notary" \
#          --apple-id "you@example.com" --team-id "TEAMID" --password "<app-specific password>"
#
# Usage:
#   DEVELOPER_ID="Developer ID Application: Your Name (TEAMID)" ./release.sh
#   (NOTARY_PROFILE overrides the keychain profile name, default "nothing-x-notary")
set -euo pipefail
cd "${0:A:h}"
: "${DEVELOPER_ID:?Set DEVELOPER_ID to your \"Developer ID Application: Name (TEAMID)\" identity}"
PROFILE="${NOTARY_PROFILE:-nothing-x-notary}"
VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" Resources/Info.plist)
APP="build/Nothing X.app"
DMG="build/NothingX-$VERSION.dmg"

SIGN_IDENTITY="$DEVELOPER_ID" HARDENED=1 TIMESTAMP=1 ./build.sh
codesign --verify --deep --strict --verbose=2 "$APP"

# Notarize and staple the app itself, so it also passes Gatekeeper offline once dragged out of the DMG.
ZIP="build/NothingX-$VERSION-notarize.zip"
rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"
xcrun notarytool submit "$ZIP" --keychain-profile "$PROFILE" --wait
xcrun stapler staple "$APP"
xcrun stapler validate "$APP"
rm -f "$ZIP"

rm -rf build/dmg "$DMG"
mkdir -p build/dmg
cp -R "$APP" build/dmg/
ln -s /Applications build/dmg/Applications
hdiutil create -volname "Nothing X" -srcfolder build/dmg -fs HFS+ -format UDZO -ov "$DMG"
codesign -s "$DEVELOPER_ID" --timestamp "$DMG"

xcrun notarytool submit "$DMG" --keychain-profile "$PROFILE" --wait
xcrun stapler staple "$DMG"
spctl --assess --type open --context context:primary-signature --verbose "$DMG"
shasum -a 256 "$DMG"
echo "Ready: $DMG"
