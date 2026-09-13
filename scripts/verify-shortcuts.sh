#!/bin/zsh
set -euo pipefail

PROJECT_ROOT="${0:A:h:h}"
QA_ROOT="$(mktemp -d /tmp/typer-shortcuts-check.XXXXXX)"
trap 'rm -rf "$QA_ROOT"' EXIT
APP_BUNDLE="$QA_ROOT/Typer Shortcut Check.app"
OUTPUT="$PROJECT_ROOT/output/shortcut-check-qa/$(date +%Y%m%d-%H%M%S)"
mkdir -p "$APP_BUNDLE/Contents/MacOS" "$OUTPUT"
cd "$PROJECT_ROOT"
swiftc -swift-version 5 -warnings-as-errors -parse-as-library \
  Sources/Typer/ShortcutBinding.swift Sources/Typer/ShortcutManager.swift \
  Sources/Typer/ShortcutRecorder.swift Sources/Typer/Theme.swift \
  scripts/verify-shortcuts.swift -o "$APP_BUNDLE/Contents/MacOS/TyperShortcutCheck"
if [[ "${1:-}" == "--compile-only" ]]; then
  echo "Shortcut verification harness compiled successfully."
  exit 0
fi
cat > "$APP_BUNDLE/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>TyperShortcutCheck</string>
<key>CFBundleIdentifier</key><string>com.tapir132.typer</string>
<key>CFBundleName</key><string>Typer Shortcut Check</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleVersion</key><string>1</string>
<key>CFBundleShortVersionString</key><string>QA</string>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
if ! security find-identity -v -p codesigning | grep -Fq '"Cadence Signing"'; then
  echo "Typer's existing signing identity is required for this graphical check." >&2
  exit 1
fi
codesign --force --sign "Cadence Signing" "$APP_BUNDLE"
open -g -W -n "$APP_BUNDLE" --args "$OUTPUT"
python3 - "$OUTPUT" <<'PY'
import json, pathlib, sys
folder = pathlib.Path(sys.argv[1])
result = json.loads((folder / 'result.json').read_text())
print(json.dumps(result, indent=2))
print('Reports:', folder)
sys.exit(0 if result['passed'] else 1)
PY
