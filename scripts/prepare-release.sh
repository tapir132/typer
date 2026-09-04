#!/bin/zsh
set -euo pipefail

if [[ $# -ne 1 || ! "$1" =~ '^[0-9]+\.[0-9]+\.[0-9]+$' ]]; then
  echo "usage: $0 X.Y.Z" >&2
  exit 2
fi

VERSION="$1"
PROJECT_ROOT="${0:A:h:h}"
RELEASE_DIR="$PROJECT_ROOT/release"
INFO_PLIST="$PROJECT_ROOT/Resources/Info.plist"
SPARKLE_BIN="$PROJECT_ROOT/.build/artifacts/sparkle/Sparkle/bin"
BUILD_NUMBER="$(git -C "$PROJECT_ROOT" show -s --format=%ct HEAD)"

/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$INFO_PLIST"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD_NUMBER" "$INFO_PLIST"
TYPER_DISTRIBUTION_BUILD=1 "$PROJECT_ROOT/scripts/build-app.sh"
mkdir -p "$RELEASE_DIR"
ARCHIVE="$RELEASE_DIR/Typer-$VERSION.zip"
rm -f "$ARCHIVE"
ditto -c -k --sequesterRsrc --keepParent "$PROJECT_ROOT/.build/Typer.app" "$ARCHIVE"
"$SPARKLE_BIN/generate_appcast" \
  --account app.cadence.updates \
  --download-url-prefix "https://github.com/tapir132/typer/releases/download/v$VERSION/" \
  --maximum-versions 5 --maximum-deltas 4 --delta-compression lzfse \
  -o "$RELEASE_DIR/appcast.xml" "$RELEASE_DIR"
DMG="$RELEASE_DIR/Typer-$VERSION.dmg"
"$PROJECT_ROOT/scripts/build-dmg.sh" "$PROJECT_ROOT/.build/Typer.app" "$DMG"
"$PROJECT_ROOT/scripts/verify-dmg.sh" "$DMG"
echo "Prepared signed update artifacts in $RELEASE_DIR"
