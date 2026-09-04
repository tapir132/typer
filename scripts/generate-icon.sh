#!/bin/zsh
set -euo pipefail

PROJECT_ROOT="${0:A:h:h}"
WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/typer-icon.XXXXXX")"
cleanup() { rm -rf "$WORK_DIR"; }
trap cleanup EXIT

SOURCE="$WORK_DIR/AppIcon-1024.png"
ICONSET="$WORK_DIR/AppIcon.iconset"
swift "$PROJECT_ROOT/scripts/generate-icon.swift" "$SOURCE"
mkdir -p "$ICONSET"

for size in 16 32 128 256 512; do
  sips -z "$size" "$size" "$SOURCE" --out "$ICONSET/icon_${size}x${size}.png" >/dev/null
  retina=$((size * 2))
  sips -z "$retina" "$retina" "$SOURCE" --out "$ICONSET/icon_${size}x${size}@2x.png" >/dev/null
done

iconutil -c icns "$ICONSET" -o "$PROJECT_ROOT/Resources/AppIcon.icns"
echo "$PROJECT_ROOT/Resources/AppIcon.icns"
