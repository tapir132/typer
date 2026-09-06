# Local realism validation

Open **Profiles → Validate rhythm**. Save at least four new sessions in the same training mode first. Copy is the best starting point: its built-in reference passage is available for matched-text generation. Live and Freewrite retain no source document; comparisons use a standard passage and are labeled as unmatched text.

The latest two eligible sessions are held out together. Only earlier sessions (up to five) fit the personal model. Natural and My rhythm use identical target WPM and seeds 17, 41 and 89. The report also compares the two human sessions with each other. This is a descriptive diagnostic, not a classifier or a probability that a trace is human.

Use **Export report…** for a reproducible JSON result containing model version, training/held-out session indices, seeds, WPM, context, matched-text status, distances, medians, median absolute deviations, counts and limitations. It contains no captured document text. The full calculations are in `Sources/Typer/TypingValidation.swift`; run their deterministic fixtures with:

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

Training never joins digraphs across a recorded Backspace, navigation, selection, unsupported chord, focus change, click, event-tap interruption or Secure Input boundary in Live capture. Locally recorded training excludes command/control/option text payloads. Live capture retains only bounded timing observations, digraph/class aggregates, edit-category counts and coarse repair timing when saved. Digraph labels still expose letter-pair usage; these are personal statistics, not anonymous data. Raw Live records remain temporary and the 15-minute limit starts when recording starts, including idle time.

Without a reference, deletion-run length is not detection distance and deletion is not necessarily error correction. Live does not infer intended substitutions. The pre-deletion interval includes preceding key hold; it is not automatically cognitive detection latency. Copy's reference alignment is conservative and is not a full text-edit alignment model.

Typer retains twelve current samples; My rhythm uses up to five recent current samples in the newly saved sample's mode. Old v1 data is kept separately in Legacy profiles for playback. Legacy profiles are locked for training and excluded from the new validation UI. New recordings never alter their saved statistics. If an earlier version replaced the Legacy profile, launch migration reconstructs one from its remaining saved samples. Deleting My rhythm removes current samples while preserving Legacy data; deleting the last Legacy profile removes its archived samples. **Delete all learned data** clears both.

## Playback invariants and limits

Plans retain the old flight/dwell JSON representation, now with signed flights. A timeline compiler prevents repeated physical keys, modifier changes, Unicode fallback and editing commands from overlapping unsafely. Shifted keys can overlap other shifted keys; the last release lifts Shift. Cancellation and posting share one per-run ledger, and completion/failure also release held keys. Deadlines are absolute on a monotonic clock; estimates use the last scheduled release.

The 500-seed/text combinations in the original text-equivalence regression exercise corrections in an abstract editor. New tests cover the scheduler and output ledger. These establish internal correctness. They do not prove all apps honor simulated key events, US-keyboard mappings, Unicode, arrow navigation or Option-Backspace identically. Realized OS event timing and external editor text should be checked in a dedicated receiver before making playback fidelity claims.

No public research dataset is bundled. Aalto and the Mendeley human/synthetic benchmark have noncommercial data terms. The latter's `FT` column is DD and uses `-1` for missing/censored values; it cannot be imported as signed flight without conversion.
