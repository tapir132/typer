# Realism and validation work plan

Scope: local native macOS implementation, September 6, 2026. Preserve exact source text, opt-in capture and v1 profiles. Research primary typing studies, benchmark definitions, statistical documentation and Apple keyboard APIs. No distribution/signing changes or public-data bundling.

- [x] Audit handoff/code and establish 14-test warnings-as-errors baseline.
- [x] Discover primary evidence in timing and validation lanes.
- [x] Reconcile evidence and implement physical timeline, bounded empirical timing, evidence weighting, repair semantics and validation.
- [x] Verify deterministic regressions, build bundle and deliver cited research artifact.

Planning API was unavailable (update_plan TypeError); this file records progress instead.

Verification: 36 tests pass with warnings as errors; final UI change also passes a warnings-as-errors build. Native release bundle rebuilt and codesign verification passes. Six-page PDF rendered and every page visually inspected. Human data collection and realized external playback measurements remain explicit empirical limitations, not claimed results.
