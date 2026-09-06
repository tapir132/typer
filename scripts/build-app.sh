#!/bin/zsh
set -euo pipefail

PROJECT_ROOT="${0:A:h:h}"
APP_BUNDLE="$PROJECT_ROOT/.build/Typer.app"
CONTENTS="$APP_BUNDLE/Contents"

cd "$PROJECT_ROOT"
"$PROJECT_ROOT/scripts/generate-icon.sh" >/dev/null
swift build -c release

if [[ "$APP_BUNDLE" != "$PROJECT_ROOT/.build/Typer.app" ]]; then
  echo "Refusing unexpected app bundle path: $APP_BUNDLE" >&2
  exit 1
fi

rm -rf "$APP_BUNDLE"
mkdir -p "$CONTENTS/MacOS" "$CONTENTS/Resources" "$CONTENTS/Frameworks"
cp "$PROJECT_ROOT/.build/release/Typer" "$CONTENTS/MacOS/Typer"
cp "$PROJECT_ROOT/Resources/AppIcon.icns" "$CONTENTS/Resources/AppIcon.icns"
sed 's/__VERSION__/1.0.0/g' "$PROJECT_ROOT/Resources/Info.plist" > "$CONTENTS/Info.plist"

# Keep local builds newer than an existing published build. Distribution jobs
# set their immutable version first and opt out of this local-only suffix.
if [[ "${TYPER_DISTRIBUTION_BUILD:-0}" != "1" ]]; then
  LOCAL_BUILD_NUMBER="$(date +%s)"
  LOCAL_REVISION="$(git -C "$PROJECT_ROOT" rev-parse --short=7 HEAD)"
  LOCAL_BUILD_DATE="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  LOCAL_HAS_CHANGES=false
  if [[ -n "$(git -C "$PROJECT_ROOT" status --porcelain --untracked-files=normal -- Sources Resources scripts Package.swift Package.resolved)" ]]; then
    LOCAL_HAS_CHANGES=true
  fi
  /usr/libexec/PlistBuddy -c "Add :TyperBuildDate string $LOCAL_BUILD_DATE" "$CONTENTS/Info.plist"
  /usr/libexec/PlistBuddy -c "Add :TyperBuildHasLocalChanges bool $LOCAL_HAS_CHANGES" "$CONTENTS/Info.plist"
  /usr/libexec/PlistBuddy -c "Set :CFBundleVersion $LOCAL_BUILD_NUMBER" "$CONTENTS/Info.plist"
  /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString 1.0.0-local.$LOCAL_REVISION" "$CONTENTS/Info.plist"
fi

SPARKLE_FRAMEWORK="$PROJECT_ROOT/.build/artifacts/sparkle/Sparkle/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework"
if [[ ! -d "$SPARKLE_FRAMEWORK" ]]; then
  echo "Sparkle.framework was not resolved by Swift Package Manager" >&2
  exit 1
fi
ditto "$SPARKLE_FRAMEWORK" "$CONTENTS/Frameworks/Sparkle.framework"

if ! otool -l "$CONTENTS/MacOS/Typer" | grep -q '@executable_path/../Frameworks'; then
  install_name_tool -add_rpath '@executable_path/../Frameworks' "$CONTENTS/MacOS/Typer"
fi
while IFS= read -r RPATH; do
  if [[ "$RPATH" == /* ]]; then
    install_name_tool -delete_rpath "$RPATH" "$CONTENTS/MacOS/Typer"
  fi
done < <(otool -l "$CONTENTS/MacOS/Typer" | awk '/cmd LC_RPATH/{getline; getline; print $2}')

# Accessibility grants are tied to the signing identity. Reusing the same local
# identity prevents macOS from silently invalidating permission after rebuilds.
IDENTITY="${TYPER_SIGNING_IDENTITY:-Cadence Signing}"
if security find-identity -v -p codesigning | grep -Fq "\"$IDENTITY\""; then
  codesign --force --deep --sign "$IDENTITY" "$APP_BUNDLE"
else
  echo "Signing identity '$IDENTITY' not found; using an ad-hoc signature" >&2
  codesign --force --deep --sign - "$APP_BUNDLE"
fi

echo "Built native macOS app: $APP_BUNDLE"
