#!/bin/zsh
# Writes build/appcast.xml for one release: signs the DMG with Sparkle's EdDSA key (read from the login
# keychain by sign_update; created once with generate_keys) and emits a single <item>.
#
# Usage: scripts/make-appcast.sh <dmg> <version> <build>
#   e.g. scripts/make-appcast.sh build/NothingX-0.2.2.dmg 0.2.2 4
# SPARKLE_BIN overrides the folder holding sign_update (default: the SwiftPM artifact bundle).
# OUT overrides the output path (default: build/appcast.xml).
set -euo pipefail
ROOT="${0:A:h:h}"
(( $# == 3 )) || { echo "usage: $0 <dmg> <version> <build>" >&2; exit 64; }
DMG="${1:A}"
VERSION="$2"
BUILD="$3"
[[ -f "$DMG" ]] || { echo "error: no such DMG: $DMG" >&2; exit 66; }

SPARKLE_BIN="${SPARKLE_BIN:-$ROOT/.build/artifacts/sparkle/Sparkle/bin}"
if [[ ! -x "$SPARKLE_BIN/sign_update" ]]; then
    (cd "$ROOT" && swift package resolve)
fi
SIGN_UPDATE="$SPARKLE_BIN/sign_update"
[[ -x "$SIGN_UPDATE" ]] || { echo "error: sign_update not found in $SPARKLE_BIN" >&2; exit 69; }

SIGNATURE=$("$SIGN_UPDATE" -p "$DMG")
[[ -n "$SIGNATURE" ]] || { echo "error: sign_update returned no signature" >&2; exit 70; }
"$SIGN_UPDATE" --verify "$DMG" "$SIGNATURE" >/dev/null || { echo "error: signature does not verify" >&2; exit 70; }
LENGTH=$(stat -f %z "$DMG")
PUBDATE=$(LC_ALL=C date -u "+%a, %d %b %Y %H:%M:%S +0000")
REPO="https://github.com/Senooy/nothing-x-mac"
URL="$REPO/releases/download/v$VERSION/NothingX-$VERSION.dmg"
NOTES="$REPO/releases/tag/v$VERSION"

OUT="${OUT:-$ROOT/build/appcast.xml}"
mkdir -p "${OUT:h}"
cat > "$OUT" <<EOF
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle" xmlns:dc="http://purl.org/dc/elements/1.1/">
    <channel>
        <title>Nothing X</title>
        <link>$REPO</link>
        <description>Nothing X for Mac updates</description>
        <language>en</language>
        <item>
            <title>Nothing X $VERSION</title>
            <link>$NOTES</link>
            <description><![CDATA[<p>Nothing X $VERSION. <a href="$NOTES">Release notes on GitHub</a>.</p>]]></description>
            <pubDate>$PUBDATE</pubDate>
            <sparkle:version>$BUILD</sparkle:version>
            <sparkle:shortVersionString>$VERSION</sparkle:shortVersionString>
            <sparkle:minimumSystemVersion>14.2</sparkle:minimumSystemVersion>
            <enclosure url="$URL" length="$LENGTH" type="application/octet-stream" sparkle:edSignature="$SIGNATURE"/>
        </item>
    </channel>
</rss>
EOF
xmllint --noout "$OUT"
echo "OK → $OUT"
