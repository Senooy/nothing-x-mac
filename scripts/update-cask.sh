#!/bin/zsh
# Points Casks/nothing-x.rb at a new release: rewrites `version` and `sha256` from the DMG.
#
# Usage: scripts/update-cask.sh <version> <dmg>
set -euo pipefail
ROOT="${0:A:h:h}"
(( $# == 2 )) || { echo "usage: $0 <version> <dmg>" >&2; exit 64; }
VERSION="$1"
DMG="$2"
[[ -f "$DMG" ]] || { echo "error: no such DMG: $DMG" >&2; exit 66; }
[[ "$VERSION" =~ '^[0-9][0-9A-Za-z.-]*$' ]] || { echo "error: bad version: $VERSION" >&2; exit 65; }
CASK="$ROOT/Casks/nothing-x.rb"
SHA=$(shasum -a 256 "$DMG" | cut -d' ' -f1)
sed -i '' -E \
    -e "s/^(  version )\"[^\"]*\"/\\1\"$VERSION\"/" \
    -e "s/^(  sha256 )\"[^\"]*\"/\\1\"$SHA\"/" \
    "$CASK"
grep -q "^  version \"$VERSION\"$" "$CASK" && grep -q "^  sha256 \"$SHA\"$" "$CASK" \
    || { echo "error: could not update $CASK" >&2; exit 70; }
echo "OK → $CASK ($VERSION, $SHA)"
