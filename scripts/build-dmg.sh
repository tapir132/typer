#!/bin/zsh
set -euo pipefail

PROJECT_ROOT="${0:A:h:h}"
APP_PATH="${1:-$PROJECT_ROOT/.build/Typer.app}"
OUTPUT_PATH="${2:-$PROJECT_ROOT/release/Typer.dmg}"

if [[ ! -d "$APP_PATH" || "${APP_PATH:t}" != "Typer.app" ]]; then
  echo "Typer.app was not found at $APP_PATH" >&2
  exit 1
fi
if [[ "${OUTPUT_PATH:e:l}" != "dmg" ]]; then
  echo "The output path must end in .dmg" >&2
  exit 1
fi

STAGING_DIR="$(mktemp -d "${TMPDIR:-/tmp}/typer-dmg.XXXXXX")"
cleanup() { rm -rf "$STAGING_DIR"; }
trap cleanup EXIT

mkdir -p "${OUTPUT_PATH:h}"
ditto "$APP_PATH" "$STAGING_DIR/Typer.app"
ln -s /Applications "$STAGING_DIR/Applications"
rm -f "$OUTPUT_PATH"
hdiutil create -volname "Typer" -srcfolder "$STAGING_DIR" -format UDZO -ov "$OUTPUT_PATH" >/dev/null

IDENTITY="${TYPER_DMG_SIGNING_IDENTITY:-}"
if [[ -z "$IDENTITY" ]]; then
  IDENTITY="$(security find-identity -v -p codesigning | sed -n 's/.*"\(Developer ID Application:[^"]*\)".*/\1/p' | head -n 1)"
fi
if [[ -n "$IDENTITY" ]]; then
  codesign --force --timestamp --sign "$IDENTITY" --identifier "com.taperi132.typer.disk-image" "$OUTPUT_PATH"
else
  echo "No Developer ID Application identity found; leaving the DMG unsigned" >&2
fi
echo "$OUTPUT_PATH"
