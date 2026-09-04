#!/bin/zsh
set -euo pipefail

if [[ $# -ne 1 || "${1:e:l}" != "dmg" || ! -f "$1" ]]; then
  echo "usage: $0 path/to/Typer.dmg" >&2
  exit 2
fi

DMG_PATH="${1:A}"
MOUNT_DIR="$(mktemp -d "${TMPDIR:-/tmp}/typer-dmg-verify.XXXXXX")"
MOUNTED=0
cleanup() {
  if [[ "$MOUNTED" == "1" ]]; then hdiutil detach "$MOUNT_DIR" -quiet || true; fi
  rmdir "$MOUNT_DIR" 2>/dev/null || true
}
trap cleanup EXIT

hdiutil verify "$DMG_PATH" >/dev/null
hdiutil attach -nobrowse -readonly -mountpoint "$MOUNT_DIR" "$DMG_PATH" >/dev/null
MOUNTED=1
[[ -d "$MOUNT_DIR/Typer.app" ]]
[[ -L "$MOUNT_DIR/Applications" ]]
[[ "$(readlink "$MOUNT_DIR/Applications")" == "/Applications" ]]
plutil -lint "$MOUNT_DIR/Typer.app/Contents/Info.plist" >/dev/null
codesign --verify --deep --strict "$MOUNT_DIR/Typer.app"
echo "Verified Typer.app and the Applications shortcut in $DMG_PATH"
