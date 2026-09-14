# Keyboard fidelity and personal timing follow-up

This pass addresses demonstrated delivery and timing gaps. It does not claim physical provenance or universal indistinguishability.

## Findings and changes

- **Personal pace was being distorted.** The saved training had about 49% rollover, while the first three personal Safari runs showed roughly 8–15%. The generator stretched learned motor intervals toward `12000 / targetWPM`, treating overall session WPM as if it described the median motor interval. It now scales by the recorded/requested WPM ratio, preserving the learned motor scale at the profile's recorded pace.
- **Averaging random timing pairs reduced variation.** The old hierarchy averaged independently sampled interval/dwell pairs. The predictive mixture now chooses a complete learned pair or a fallback draw using observation-based weights. Fixed random draw counts preserve reproducibility. Pseudocounts and support bounds remain engineering choices.
- **Physical layout mappings replace a hardcoded U.S. assumption.** An immutable layout snapshot enumerates printable direct keys and two-key accent sequences using Apple's translation API. It considers keyboard shape, prefers direct unmodified keys, and preserves exact Unicode fallback for unmatched text. TIS calls must stay on the main thread; concurrent input-source calls caused a test crash and were corrected before release.
- **Dead-key state is opaque.** On this Mac, translating Option-E then E returns `é` with nonzero key-up bookkeeping. Treating every nonzero state as pending composition wrongly discarded valid mappings. The resolver instead checks that a following space is unchanged and clears the state, without decoding private bits.
- **Modifiers and accents use the scheduler.** Bounded leads/lags, prefix strokes and cleanup are on the production path. AppKit checks cover pausing, cancelling and failing after an accent prefix, including absence of marked text and exact output after resuming.
- **Broader browser observations.** Added legacy key codes, keypress, event flags and modifier states, with explicit coverage for older imports. Added accent, longer-text and contenteditable scenarios, read-only saved-profile testing and matched Natural controls.
- **Rich text required a distinct receiver check.** Safari inline suggestions introduced extra composition and missing keydown observations despite final visible text. The local test fields now disable predictions with `writingsuggestions="false"`. Their DOM text projection avoids the extra terminal block newline from Safari `innerText`; raw HTML stays in the report. No system or Safari preference was changed.

## Exploratory saved-session comparison

Three stored Copy sessions were available. Each fold trained on the other two sessions, with seeds 17, 41 and 89 and matched Natural/personal WPM. The same folds and seeds were run before and after the timing changes. The physical Safari reference was not used as training data.

| Descriptive W1 distance, median across 9 paired trials | Natural | Personal before | Personal after |
| --- | ---: | ---: | ---: |
| Press interval | 65.8 ms | 93.2 ms | 21.1 ms |
| Signed flight | 79.3 ms | 93.2 ms | 20.8 ms |
| Overlap duration | 10.4 ms | 20.0 ms | 4.6 ms |

These are development measurements on retained sessions. Seeds are not independent people or sessions. Older recordings do not verify final prompt completion, so the audit retains `textMatched=false`. The in-app validation gate remains unchanged. Two newly completed Copy samples would provide two independent, completion-verified held-out sessions while retaining the three older sessions for training.

Local artifacts: `output/browser-check/personal-profile-audit-before.json`, `personal-profile-audit.json`, and `layout-personal-final/`. No raw personal sample or profile is committed.

## Final native verification

- 113 Swift tests passed with warnings treated as errors; 27 browser analyzer tests passed.
- Three AppKit fixtures plus pause/resume, cancellation and output-failure composition checks passed.
- All 19 native Safari runs passed: exact projected text, balanced trusted key events and successful native completion. This includes all default Natural, matched 92 WPM Natural and personal seeds, direct symbols, accents, longer text and rich text.
- Personal Safari seeds 1–3 at the saved 92 WPM produced 66.7%, 56.1% and 43.9% rollover; the existing physical sample had 46.7%. Holds were 96, 90 and 88 ms median versus 93 ms physical. Faster playback than the recorded profile's 75.3 WPM can legitimately increase overlap.
- All shared logical-key property groups matched the older physical reference. The reference did not capture the newly added fields; their comparison is unavailable. Full event sequences still differ, and press-interval distances against this short reference remain mixed.
- Desktop/mobile checker UI and saved-reference import were exercised with labelled browser automation; those interactions were not used as a physical reference. Release build and standalone shortcut-harness compilation passed.

## Remaining manual evidence

Record fresh physical samples with the expanded checker for everyday text, modifiers, accent composition and the rich-text passage. The old physical reference lacks the new fields; those comparisons remain unavailable. Repeat in representative target editors and any other input layout actually used. Direct mapping tests for five installed layouts do not substitute for those end-to-end runs. IMEs without direct layout data are deliberately unsupported.

Native applications can still inspect macOS event-source metadata. A browser property comparison cannot establish equivalence to keyboard hardware. Modifier timing defaults are not a learned modifier model, and broader timing validation still needs independent sessions and more than one task.

## Primary sources

- [Apple: UCKeyTranslate](https://developer.apple.com/documentation/coreservices/1390584-uckeytranslate): layout translation and opaque state. This is a mapping/compiler use; ordinary application input remains with the native text system.
- [W3C UI Events](https://www.w3.org/TR/uievents/): keyboard identity, composition, event order and legacy properties. Platform/input-method differences remain observable and legitimate.
- [WebKit: Safari 18 writing suggestions](https://webkit.org/blog/15865/webkit-features-in-safari-18-0/): the per-element switch for inline predictions.
- [HTML writing suggestions](https://html.spec.whatwg.org/multipage/interaction.html#writing-suggestions): attribute behavior, including the possibility of user preference overrides.
- [Aalto 136-million-keystroke study](https://userinterfaces.aalto.fi/136Mkeystrokes/): individual variation and rollover motivate preserving paired timing instead of assigning a universal cadence. No dataset is bundled.
- [Apple event-source PID](https://developer.apple.com/documentation/coregraphics/cgeventfield/eventsourceunixprocessid): the native provenance boundary remains.
