#!/bin/zsh
set -euo pipefail

PROJECT_ROOT="${0:A:h:h}"
cd "$PROJECT_ROOT"

swift build -c release

APP_BUNDLE="$PROJECT_ROOT/.build/Typer.app"
EXECUTABLE="$PROJECT_ROOT/.build/release/Typer"

if [[ "$APP_BUNDLE" != "$PROJECT_ROOT/.build/Typer.app" ]]; then
  echo "Refusing unexpected app bundle path: $APP_BUNDLE" >&2
  exit 1
fi

rm -rf "$APP_BUNDLE"
mkdir -p "$APP_BUNDLE/Contents/MacOS" "$APP_BUNDLE/Contents/Resources"
cp "$EXECUTABLE" "$APP_BUNDLE/Contents/MacOS/Typer"
cp "$PROJECT_ROOT/Resources/AppIcon.icns" "$APP_BUNDLE/Contents/Resources/AppIcon.icns"

sed "s/__VERSION__/1.0.0/g" "$PROJECT_ROOT/Resources/Info.plist" > "$APP_BUNDLE/Contents/Info.plist"
codesign --force --deep --sign - "$APP_BUNDLE"

echo "Built native macOS app: $APP_BUNDLE"
