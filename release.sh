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

# Sparkle appcast (EdDSA signature of the final, stapled DMG) and Homebrew cask. The DMG above is final
# either way; if one of these steps fails, say so loudly, keep going, and exit non-zero at the end.
BUILD=$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" Resources/Info.plist)
FAILED=()
scripts/make-appcast.sh "$DMG" "$VERSION" "$BUILD" || FAILED+=("appcast (scripts/make-appcast.sh)")
scripts/update-cask.sh "$VERSION" "$DMG" || FAILED+=("cask (scripts/update-cask.sh)")

cat <<EOF

Next steps (not run by this script):
  git add Casks/nothing-x.rb && git commit -m "Cask: nothing-x $VERSION"
  gh release create "v$VERSION" "$DMG" build/appcast.xml --repo Senooy/nothing-x-mac --title "Nothing X $VERSION" --notes-file build/release-notes-$VERSION.md
  # or, if the release already exists:
  gh release upload "v$VERSION" "$DMG" build/appcast.xml --repo Senooy/nothing-x-mac --clobber
The appcast must be attached to every release: SUFeedURL points at releases/latest/download/appcast.xml.
EOF
if (( ${#FAILED} )); then
    print -u2 "\n*** RELEASE INCOMPLETE: failed step(s): ${(j:, :)FAILED}. Fix and rerun them by hand. ***"
    exit 1
fi
