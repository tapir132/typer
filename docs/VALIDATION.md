# Local realism validation

Open **Profiles → Validate rhythm**. Select the training context; its ready count requires at least 20 paired timings per current session. Four sessions enable a comparison. Copy/Sprint comparisons are matched only when the final editor text was verified against the full prompt at capture. Partial and older unverified samples still work, with unmatched/unverified labels. This optional completion field does not make current samples Legacy. Live and Freewrite retain no source document; comparisons use a standard passage and are labeled as unmatched text.

The latest two eligible sessions are held out together. Only earlier sessions (up to five) fit the personal model. Natural and My rhythm use identical target WPM and seeds 17, 41 and 89. The report also compares the two human sessions with each other. This is a descriptive diagnostic, not a classifier or a probability that a trace is human.

The default overview reports median W1 distances and their minimum–maximum range across paired trials. A pair must share held-out session, training session indices, seed, WPM and matched-text status. Both modes need an available distance for the metric; unavailable data stay unavailable. Different seeds share the same human observations and are not independent human replicates. The human-to-human reference can include different passages and is not a pass threshold.

Use **Export report…** for a reproducible version-2 JSON result containing model version (`paired-timing-v3-context-pauses`), training/held-out session indices, seeds, WPM, context, matched-text status, distances, medians, median absolute deviations, counts and limitations. It contains no captured document text. The full calculations are in `Sources/Typer/TypingValidation.swift`; run their deterministic fixtures with:

```sh
swift test -Xswiftc -warnings-as-errors
```

## Definitions

- Hold: key-up minus that key's key-down.
- Press interval (DD): consecutive character key-down difference.
- Signed flight (UD): next key-down minus preceding key-up. Negative means overlap. `DD = preceding hold + UD`.
- Rollover: fraction of eligible adjacent character pairs whose signed flight is negative. This denominator differs from papers using all keypresses.
- KS distance: largest absolute difference between empirical cumulative distributions, from zero to one.
- Wasserstein-1 (W1): area between those cumulative distributions. Timing W1 is in milliseconds; burst and deletion-run W1 uses keys/actions.
- Missing/empty metrics return unavailable. Zero is reserved for a measured zero difference.
- Autocorrelation: Pearson correlation between adjacent eligible DD values, without crossing edits, invalid intervals or capture boundaries. Undefined for fewer than three interval pairs or zero variance.

Distances use bounded retained observations, not every captured event. Reports separately identify total observed pairs, retained counts and missing holds. Keystroke samples are dependent and clocks quantized; no conventional KS p-value is calculated. Small samples are diagnostic only. Independent additional sessions are required to confirm any tuning performed after viewing these results.

## Filtering and privacy

Hold observations must be finite and in 10–500 ms. Motor pairs require DD in 15–2500 ms and a valid preceding hold. Pauses retain DD from 1000 to 60000 ms, separately. Burst boundaries use 310 ms. These thresholds are engineering choices. Generator holds use a narrower 20–250 ms support. The definition of a burst excludes isolated single-key episodes, so the report is specifically about multi-key motor bursts.

Training never joins digraphs across a recorded Backspace, navigation, selection, unsupported chord, focus change, click, scroll, idle gap over 2.5 seconds, sleep, event-tap interruption or Secure Input boundary in Live capture. Locally recorded training excludes command/control/option text payloads. Live capture retains only bounded timing observations, digraph/class aggregates, edit-category counts and coarse repair timing when saved. Digraph labels still expose letter-pair usage; these are personal statistics, not anonymous data. Raw Live records remain temporary. The one-hour limit starts when recording starts, uses ContinuousClock to include idle and sleep time, and is checked on timer ticks, event receipt, and wake. A 100,000-record ceiling also bounds exceptional high-volume sessions.

Live active WPM divides counted character arrivals by contiguous typing intervals (15–2500 ms), including intervals spent deleting. The first key after a break contributes no instantaneous character to this estimate. Navigation/selection, ignored chords and autorepeat reset the active-speed sequence. Key releases supply dwell measurements but never extend active time. Saving requires 35 characters, 20 usable paired timings, and a finite active-speed estimate; isolated scattered keys cannot produce a valid profile.

Live capture deliberately excludes pooled and contextual thinking-pause observations, including when existing Live samples are merged or validated. It cannot distinguish reading and browsing from planning text. In-app Copy, Freewrite, and Sprint pause measurements are unchanged. Older Live samples lack active-time counters; their training/validation WPM is estimated as 12,000 divided by the mean retained valid motor interval. Old stored profiles cannot replay learned thinking pauses in Live context. No raw records are needed to use the older motor evidence.

Live preview summarization runs on the timer at most once every two seconds over the latest 2,000 records, with whole-session active speed. Saving summarizes the full session once and drops raw records. Saved timing distributions remain bounded; no ordered activity history, document text, or application names are added to persistence. The 2.5-second segmentation cutoff is a conservative engineering choice, not a claim that every shorter interval is uninterrupted writing.

Without a reference, deletion-run length is not detection distance and deletion is not necessarily error correction. Live does not infer intended substitutions. The pre-deletion interval includes preceding key hold; it is not automatically cognitive detection latency. Copy's reference alignment is conservative and is not a full text-edit alignment model.

Typer retains twelve current samples; My rhythm uses up to five recent current samples in the newly saved sample's mode. Old v1 data is kept separately in Legacy profiles for playback. Legacy profiles are locked for training and excluded from the new validation UI. New recordings never alter their saved statistics. If an earlier version replaced the Legacy profile, launch migration reconstructs one from its remaining saved samples. Deleting My rhythm removes current samples while preserving Legacy data; deleting the last Legacy profile removes its archived samples. **Delete all learned data** clears both.

## Playback invariants and limits

Plans retain the old flight/dwell JSON representation, now with signed flights. A timeline compiler prevents repeated physical keys, modifier changes, Unicode fallback and editing commands from overlapping unsafely. Shifted keys can overlap other shifted keys; the last release lifts Shift. Cancellation and posting share one per-run ledger, and completion/failure also release held keys. Deadlines are absolute on a monotonic clock; estimates use the last scheduled release.

The 500-seed/text combinations in the original text-equivalence regression exercise corrections in an abstract editor. New tests cover the scheduler and output ledger. These establish internal correctness. They do not prove all apps honor simulated key events, US-keyboard mappings, Unicode, arrow navigation or Option-Backspace identically. Realized OS event timing and external editor text should be checked in a dedicated receiver before making playback fidelity claims.

No public research dataset is bundled. Aalto and the Mendeley human/synthetic benchmark have noncommercial data terms. The latter's `FT` column is DD and uses `-1` for missing/censored values; it cannot be imported as signed flight without conversion.


## Actual local playback check

Open **Profiles → Check playback on this Mac**. The three fixed scenarios exercise rollover and repeated keys, Shift transitions, character and word deletion, selection replacement, cursor insertion, punctuation, Return, Tab and Unicode. They use the same scheduler and Core Graphics event factory as Compose. The transport addresses only Typer's own process, and an application-lifetime router consumes tagged diagnostic events so queued keys cannot leak into another Typer field after cancellation. The dedicated receiver uses normal AppKit text interpretation with automatic substitutions disabled.

The run checks byte-exact UTF-8 text, expected key-down/up receipts, duplicates, unexpected keys, ordering and Shift/Option flags. Complete neighboring character pairs supply planned and observed rollover. Modifier events are excluded from the stroke counts. Cancellation, physical key input, loss of application focus or loss of the test editor end the run. A 750 ms drain window allows final receipts after scheduling completes; a later event is treated as missing from that run.

Per-event observations retain the NSEvent timestamp and the handler's monotonic receipt time, both relative to the scheduler origin. Median and nearest-rank p95 absolute errors compare planned and received hold, press interval and signed flight. Separate rows show receipt-vs-schedule error and receipt-vs-event-timestamp delay. Invalid nonfinite measurements increment the unexpected count and are excluded from exported receipts.

No timing threshold is certified. Passing text/event integrity can coexist with poor timing: a stalled receiver can handle a batch with accurate original timestamps. The deterministic regression explicitly exercises this distinction. This does not measure a physical keyboard, the global HID delivery route, or another editor's behavior. No newly captured human evidence is claimed.

For a graphical integration check, run `scripts/verify-playback.sh`. It builds a temporary application from the production scheduler, event factory and receiver sources, then runs a normal AppKit event loop. Generated events address only that test process. JSON reports and screenshots are saved under `output/playback-check-qa`; the temporary app is removed afterward. This requires a logged-in graphical session, Typer's normal signing identity and its existing Accessibility grant. The harness uses an isolated background receiver so it does not take focus from other work. The normal in-app check still requires foreground focus; the background harness does not test that policy. It never edits permissions or loads the user's profiles or live-capture state. Regular CI exercises the deterministic analysis and output-ledger tests without requiring this GUI check.


## Contextual pauses and playback controls

New samples retain optional pause summaries for within-word, word-boundary and sentence-boundary contexts. Each observation is the longest valid key-up-to-next-press idle across that boundary, including adjacent spaces and closing punctuation; an unfinished boundary contributes nothing. Finite holds must be 10–500 ms and DD 15–60000 ms. Edits, missing holds and invalid gaps break the sequence. A long pause is at least 1000 ms; its category is inferred from punctuation and spacing, so abbreviations remain ambiguous. This definition differs from the older pooled DD pause row. Contextual duration rows compare retained long pauses; Detailed trials and exported pauseRates also show pause and opportunity counts, rates and absolute percentage-point gaps. Missing contexts are unavailable, while positive opportunities with no observed pauses produce a measured zero rate. The cutoffs are engineering choices, not universal cognitive boundaries.

Each sample retains at most 128 durations per category. Merging caps each session at 512 opportunities and 32 retained durations, with a final cap of 128. Frequency uses the capped opportunity counts; the support gate requires at least 20 opportunities, three observed pauses and three retained valid durations across two sessions. My rhythm uses supported categories only when the training mode is known, shrinks frequency and duration toward fallback behavior, and keeps Copy/Freewrite/Sprint/Live contexts separate. Supported sentence evidence replaces the generic occasional thought stall. Explicit Sentence pauses takes the longer wait at the same boundary. Timing and repair choices are made before learned/manual waits are sampled.

Older current profiles and samples decode without these optional fields. They remain usable for timing and validation, with unavailable pause rows where evidence is missing; no statistics are invented and no data reset is required. Legacy migration and training locks are unchanged. Coverage thresholds for timing (120 pairs), rollover (120 retained pairs) and corrections (10 deletion runs) are descriptive guidance, not pass/fail realism criteria. Fresh same-context human sessions are required to evaluate whether the added pause model actually improves fit.

The scheduler freezes a monotonic virtual clock during pause and releases all held keys/modifiers. Resuming does not replay already posted key-downs. Skipping advances that clock by only the remaining eligible long wait; later intervals remain intact. Cancellation still interrupts paused or waiting sessions. The fullscreen panels cannot become key/main windows and ignore mouse events. App activation changes trigger pause; this is not an atomic lock on the external editor or its insertion point.

The in-app text preview shares the plan and scheduler, but applies edits to an abstract in-memory editor. It neither posts OS keys nor persists source text. Its text equality check, scheduler tests and native receiver checks establish separate properties and do not certify every external editor. Changing timing, pause or preset controls regenerates the preview; skip only changes the current run.
