# Verification record - September 6, 2026

- Baseline: 14 tests passed with `swift test -Xswiftc -warnings-as-errors`.
- Expanded suite: 36 tests passed with the same command (last run 0.531 s).
- Final training readout change: `swift build -Xswiftc -warnings-as-errors` passed.
- Native bundle: `./scripts/build-app.sh` passed; `.build/Typer.app` rebuilt after final changes.
- Signature structure: `codesign --verify --deep --strict .build/Typer.app` passed. This is a local build, not a notarization/distribution claim.
- Whitespace: `git diff --check` passed.
- Research artifact: `output/pdf/typer-realism-research.pdf`, six pages, 26 hyperlink annotations. All six rendered pages visually inspected for clipping, overlap, citation formatting and page breaks.
- Regression coverage includes 500 original source/seed combinations, physical timeline ordering, cancel/failure cleanup, actual monotonic scheduler execution with an injected sink, old-schema decoding, empirical shrinkage, invalid inputs, context isolation, held-out separation, deterministic distances, autocorrelation and profile deletion.
- Controlled generated fixtures improve hold/rollover fit when supplied with matching personal evidence. These fixtures are not human observations.
- At the end of the research pass, no new human sessions, globally posted playback test, external editor receiver measurements, or native UI screenshot/interaction audit had been performed. Those limitations are stated in the research artifact and validation protocol. The subsequent UI work is recorded below.
- The pre-existing untracked `handoff.md` was read and preserved.

## UI and updater follow-up

- Reproduced the reported header movement in a native `NSWindow`/`NSHostingView`: Compose's header began at y = −7 points at 1240 × 800, versus y = 28 for Train and Profiles. At 920 × 660, Compose began at y = −77. The initial regression test failed on clipping and unequal header positions.
- Pinned the header to the window's available geometry and put overflowing workspace content in a scroll view. The same test now passes across Compose, Train, Profiles, Guide, and back to Compose, at both sizes.
- Native screenshots visually checked for all four workspaces at both sizes, the System setup switch alignment, and all eight Guide topics. Artifacts are in `output/layout-after/`; initial reproductions are in `output/layout-before/`. These are offscreen native renders, not screenshots of the still-running older app.
- Added small help buttons using native hover tooltips and click/keyboard popovers beside controls and measurements. Hover timing and live interaction in the user's running app were not exercised; that process still contains the previous build.
- Expanded suite: 41 tests passed with `swift test -Xswiftc -warnings-as-errors`, including layout, local build identity, Sparkle's build-number ordering, no-update reasons, incompatible macOS reporting, and update failure recovery. Additional native screenshot capture passed after extending the QA harness.
- Verified both published appcasts returned HTTP 200. Their latest internal build was `1788545750` from September 4. The inspected local build was newer (`1788722395`), while the running process had started September 4 at 11:20:18 local time. No release containing today's local edits had been published.
- System setup now shows build origin/date, unpublished-change metadata, and update-check results. The existing local timestamp version ordering and signature verification remain in place.
- Rebuilt `.build/Typer.app` after the guide/help changes; signature verification and shell syntax checks passed. Save unfinished work and quit/reopen the rebuilt app to load it. No forced restart, release publication, live recording, or external-editor key injection was performed.
- Older-profile follow-up: added a conditional “Older profile · still usable” explanation in Profiles, a shorter note in Compose's My rhythm controls, and guidance on retaining older data in the Guide. Native layout checks passed with an older profile loaded from isolated test preferences at both supported test sizes; Profiles and Compose screenshots were visually inspected in `output/older-profile-qa/`. The built-in baseline does not receive the older-profile label.
- Legacy locking follow-up: replaced that explanatory-only treatment with separate, playback-only Legacy profiles. New recordings cannot update them, old-format recordings are rejected as new training, and the twelve-current-sample limit leaves the Legacy archive intact. Launch migration preserves existing Legacy IDs/statistics or recovers a separate Legacy rhythm from older samples if an earlier build replaced it. Deletion tests verify that removing one profile preserves the other and does not recreate deleted data on launch.
- The saved-total / profile-training discrepancy was verified using counts only from local preferences: four Legacy samples and one new Copy sample, with the current profile trained on one. Both views now explicitly distinguish those counts. Native screenshots of the two separate profiles and the training destination were inspected in `output/legacy-lock-qa/`. Full suite: 46 tests passed with warnings treated as errors. The user's live preferences were not modified during this work; migration takes effect when the rebuilt app is relaunched.
