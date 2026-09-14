#!/bin/zsh
set -euo pipefail
PROJECT_ROOT="${0:A:h:h}"
QA_ROOT="$(mktemp -d /tmp/typer-profile-audit.XXXXXX)"
trap 'rm -rf "$QA_ROOT"' EXIT
cd "$PROJECT_ROOT"
if [[ $# != 2 ]]; then echo 'Usage: audit-profile.sh PRIVATE_SNAPSHOT.json REPORT.json' >&2; exit 1; fi
swiftc -swift-version 5 -warnings-as-errors -parse-as-library \
 Sources/Typer/Models.swift Sources/Typer/GlobalTrainingCapture.swift Sources/Typer/Theme.swift Sources/Typer/HelpTip.swift \
 Sources/Typer/TimingEvidence.swift Sources/Typer/PauseLearning.swift Sources/Typer/TypingEngine.swift Sources/Typer/TypingValidation.swift \
 Sources/Typer/KeyboardLayout.swift Sources/Typer/KeyTimeline.swift Sources/Typer/ShortcutBinding.swift Sources/Typer/ShortcutManager.swift Sources/Typer/TypingController.swift \
 Sources/Typer/TrackingTextView.swift Sources/Typer/TypingScreenOverlay.swift scripts/browser-check/profile-audit.swift -o "$QA_ROOT/profile-audit"
"$QA_ROOT/profile-audit" "$1" "$2"
