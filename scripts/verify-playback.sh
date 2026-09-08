#!/bin/zsh
set -euo pipefail

PROJECT_ROOT="${0:A:h:h}"
QA_ROOT="$(mktemp -d /tmp/typer-playback-check.XXXXXX)"
trap 'rm -rf "$QA_ROOT"' EXIT
APP_BUNDLE="$QA_ROOT/Typer Playback Check.app"
OUTPUT="$PROJECT_ROOT/output/playback-check-qa/$(date +%Y%m%d-%H%M%S)"
mkdir -p "$APP_BUNDLE/Contents/MacOS" "$OUTPUT"

cd "$PROJECT_ROOT"
# Compile the production components, without loading Typer's user preferences,
# application model, updater or global capture.
swiftc -swift-version 5 -warnings-as-errors -parse-as-library \
  Sources/Typer/Models.swift Sources/Typer/Theme.swift Sources/Typer/HelpTip.swift \
  Sources/Typer/TimingEvidence.swift Sources/Typer/PauseLearning.swift Sources/Typer/TypingEngine.swift \
  Sources/Typer/KeyTimeline.swift Sources/Typer/TypingController.swift \
  Sources/Typer/TrackingTextView.swift Sources/Typer/TypingScreenOverlay.swift Sources/Typer/PlaybackCheck.swift \
  Sources/Typer/PlaybackCheckController.swift Sources/Typer/PlaybackCheckView.swift \
  scripts/verify-playback.swift -o "$APP_BUNDLE/Contents/MacOS/TyperPlaybackCheck"

cat > "$APP_BUNDLE/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>TyperPlaybackCheck</string>
<key>CFBundleIdentifier</key><string>com.tapir132.typer</string>
<key>CFBundleName</key><string>Typer Playback Check</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>QA</string>
<key>CFBundleVersion</key><string>1</string>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
# This is a build of Typer's playback components, so reuse Typer's ordinary
# identity and permission grant just as build-app.sh does. Never edit TCC.
IDENTITY="Cadence Signing"
if ! security find-identity -v -p codesigning | grep -Fq "\"$IDENTITY\""; then
  echo "Typer's signing identity is required to reuse its Accessibility grant for this graphical check." >&2
  exit 1
fi
codesign --force --sign "$IDENTITY" "$APP_BUNDLE"
open -g -W -n "$APP_BUNDLE" --args "$OUTPUT"
python3 - "$OUTPUT" <<'PY'
import json, pathlib, sys
folder = pathlib.Path(sys.argv[1])
result = json.loads((folder / 'result.json').read_text())
print(json.dumps(result, indent=2))
print('Reports and screenshots:', folder)
if not result['passed']:
    sys.exit(1)
PY
