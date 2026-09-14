#!/bin/zsh
set -euo pipefail
PROJECT_ROOT="${0:A:h:h}"
QA_ROOT="$(mktemp -d /tmp/typer-browser-check.XXXXXX)"
trap 'rm -rf "$QA_ROOT"' EXIT
APP_BUNDLE="$QA_ROOT/Typer Browser Check.app"
OUTPUT="$PROJECT_ROOT/output/browser-check/$(date +%Y%m%d-%H%M%S)"
mkdir -p "$APP_BUNDLE/Contents/MacOS" "$OUTPUT"
cd "$PROJECT_ROOT"
swiftc -swift-version 5 -warnings-as-errors -parse-as-library \
  Sources/Typer/Models.swift Sources/Typer/GlobalTrainingCapture.swift Sources/Typer/Theme.swift Sources/Typer/HelpTip.swift \
  Sources/Typer/TimingEvidence.swift Sources/Typer/PauseLearning.swift Sources/Typer/TypingEngine.swift Sources/Typer/TypingValidation.swift \
  Sources/Typer/KeyboardLayout.swift Sources/Typer/KeyTimeline.swift Sources/Typer/ShortcutBinding.swift Sources/Typer/ShortcutManager.swift Sources/Typer/TypingController.swift \
  Sources/Typer/TrackingTextView.swift Sources/Typer/TypingScreenOverlay.swift \
  scripts/browser-check/native.swift -o "$APP_BUNDLE/Contents/MacOS/TyperBrowserCheck"
if [[ "${1:-}" == "--compile-only" ]]; then
  echo "Safari native verification harness compiled successfully."
  exit 0
fi
if ! command -v node >/dev/null; then
  echo "Node.js is required for the local Safari check server." >&2; exit 1
fi
INPUT_SOURCE="$(defaults read com.apple.HIToolbox AppleCurrentKeyboardLayoutInputSourceID)"
if [[ "$INPUT_SOURCE" != "com.apple.keylayout.US" ]]; then
  echo "These fixed keyboard fixtures currently require the U.S. input layout. Current: $INPUT_SOURCE" >&2; exit 1
fi
PROFILE_SNAPSHOT=""
if (( ${@[(Ie)--with-saved-profile]} )); then
  PROFILE_SNAPSHOT="$QA_ROOT/private-profile.json"
  python3 scripts/browser-check/export-profile.py "$PROFILE_SNAPSHOT"
  "$APP_BUNDLE/Contents/MacOS/TyperBrowserCheck" --validate-profile "$PROFILE_SNAPSHOT" "$OUTPUT/held-out-validation.json"
fi
"$APP_BUNDLE/Contents/MacOS/TyperBrowserCheck" --fixtures "$PROFILE_SNAPSHOT" > "$QA_ROOT/fixtures.json"
cat > "$APP_BUNDLE/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>TyperBrowserCheck</string>
<key>CFBundleIdentifier</key><string>com.tapir132.typer</string>
<key>CFBundleName</key><string>Typer Browser Check</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>QA</string>
<key>CFBundleVersion</key><string>1</string>
</dict></plist>
PLIST
if ! security find-identity -v -p codesigning | grep -Fq '"Cadence Signing"'; then
  echo "Typer's signing identity is required to reuse its existing Accessibility grant." >&2; exit 1
fi
codesign --force --sign 'Cadence Signing' "$APP_BUNDLE"
SERVER_ARGS=()
if (( ! ${@[(Ie)--no-open]} )); then SERVER_ARGS+=(--open); fi
if (( ${@[(Ie)--global-hid]} )); then SERVER_ARGS+=(--global-hid); fi
node scripts/browser-check/server.mjs "$APP_BUNDLE" "$QA_ROOT/fixtures.json" "$QA_ROOT" "$OUTPUT" "$PROFILE_SNAPSHOT" "${SERVER_ARGS[@]}"
