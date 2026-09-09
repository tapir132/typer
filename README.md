# Typer

Typer is a fully native SwiftUI macOS app that performs pasted text with human cadence. It supports selectable WPM, overlapping key presses, signed flight time, paired dwell/interval observations, per-digraph timing, punctuation and thinking pauses, adjacent-key slips, transpositions, duplicate keys, omission/insertion repairs, whole-word substitutions, immediate backspaces, delayed repairs, fatigue drift, and learned personal typing profiles.

## Run it

```bash
swift run Typer
```

To build a normal `.app` bundle:

```bash
chmod +x scripts/build-app.sh
./scripts/build-app.sh
open .build/Typer.app
```

The build script uses the local `Cadence Signing` identity when available so Accessibility permission survives rebuilds; contributors without it receive an ad-hoc-signed build. On first use, open Typer's settings and enable Accessibility permission in **System Settings → Privacy & Security → Accessibility**.

## Workflow

1. Paste or write source text in **Compose**.
2. Choose WPM and realism settings.
3. Click **Arm typing**.
4. During the five-second countdown, focus any editable field in another app.
5. Press **⌘⌥P** to pause/resume, **⌘⌥→** to skip a long wait, or **⌘ Esc / ⌃ Esc** to stop.

During playback, a red fullscreen overlay covers connected screens with a large pause/resume shortcut, destination, progress and wait label. It stays visible with a lighter tint while paused and disappears on stop or completion. It does not take keyboard focus and passes mouse clicks through. **Compose → Fullscreen typing overlay** toggles it; the default is on.

Pause releases held keys and freezes the run's clock. Resume continues from that point; skip shortens only the current long wait. Switching apps pauses playback, and resuming requires the original app to be active. Focus the same text field and avoid moving the cursor or editing unfinished output. Typer remembers the app, but cannot restore or lock an insertion point within it.

**Play preview** above Source text plays the current plan in an in-memory editor, showing the actual text, corrections, labeled waits and remaining time. It supports pause/resume, skip and stop without posting OS keys or requiring Accessibility. The preview is an abstract editor; external apps may interpret edits differently. Arm uses the same plan while text/settings remain unchanged.

Compose remembers controls across launches. The **Preset** menu includes Quick messages, Long-form writing and Clean copy. **Save…** stores a named setup; up to 30 personal presets can be kept and removed from the menu. Presets save controls, including the overlay, but never source text or a learned-profile selection.

Open the gear (or press **⌘,**) for **Settings → Guide**, or use **Help → Typer Guide**. Short topic-based answers cover first runs, controls, training, measurements, validation, privacy, and updates, with extra details folded away. Hover or click a small **?** beside a control for quick help. Opening Settings preserves your current workspace and unfinished training exercise.

Use **Train** in three ways: **Copy** learns exact errors and digraphs, **Freewrite** learns organic thought pauses, and **Sprint** learns fast bursts and recovery reflexes. The profiler measures dwell time, flight time, press-to-press digraph latency, timing variation, burst length, correction rate, detection delay, repair latency, and recurring substitutions. Profiles and samples stay in macOS user defaults on this Mac.

**Live capture** is an optional fourth mode for learning while you write in Google Docs or another application. It uses a listen-only event tap, never intercepts or delays the target application's input, pauses while macOS Secure Input is enabled, stops automatically after one hour, and discards raw keystrokes when the session ends. Only derived timing and correction statistics are saved. Live capture requires the separate macOS **Input Monitoring** permission and never starts without an explicit click.

You can leave Live capture on while using your Mac for up to an hour. Gaps over 2.5 seconds, app changes, clicks, scrolling, sleep, and Secure Input break the sequence. **Active speed** uses contiguous typing intervals, including deletion time, and excludes those breaks. The session timer includes idle and sleep time. Live capture learns key timings and corrections, while Freewrite remains the way to learn thinking pauses: Live cannot distinguish thinking from reading or browsing.

The live fingerprint refreshes from recent keys; saving summarizes the full session once. A sample needs 35 characters and 20 usable key pairs, so occasional isolated key presses cannot become a misleading profile. Existing Live samples remain usable: when retraining or validating, their active pace is estimated from retained motor intervals and their pause evidence is excluded. There is no need to clear old profiles.

### Mistakes and corrections during training

Correct mistakes in all three modes exactly as you naturally would. Do not deliberately manufacture typos, rush a correction, or leave an error behind just to give the model more data.

- **Copy:** Type the passage accurately and fix genuine mistakes using your normal correction behavior.
- **Freewrite:** Compose fresh text in the box. Pause, revise, delete words, and correct mistakes naturally.
- **Sprint:** Type quickly, but still correct a mistake when that is your normal reflex.

Corrections are useful training data. Copy can learn aligned substitutions and detection distance; Freewrite and Live learn observed deletion runs, edit categories and repair timing without guessing the intended text. If you genuinely would not notice a particular mistake, leaving it is also representative—just do not make that choice artificially for the test.

## How the model works

Personal timing backs off from exact letter pairs to assumed QWERTY hand/finger classes, pooled personal observations, and a log-normal fallback. Counts of valid observations control shrinkage; each session's contribution is capped. Joint preceding-hold/press-interval observations preserve signed flight and allow rollover. Commands, repeated physical keys and modifier transitions remain scheduling barriers. The displayed estimate includes the last scheduled key release.

Typer keeps twelve current samples, with up to five recent samples from the newly saved training mode used for My rhythm. Legacy profiles and their saved samples are kept separately for playback; they cannot accept new training or use the new validation system. New recordings leave Legacy profiles unchanged. If an earlier build replaced a Legacy profile, launch migration recovers a separate Legacy rhythm from its remaining saved samples. Existing v1 profiles remain readable; new observations supply the paired timing evidence they lack. **Profiles → Delete all learned data** clears profiles and samples.

The approach is informed by the [CMU keystroke-dynamics benchmark](https://www.cs.cmu.edu/~keystroke/), research showing that immediate and delayed repairs have measurably different timing ([Correction Without Consciousness in Complex Tasks](https://pmc.ncbi.nlm.nih.gov/articles/PMC8740635/)), and field research using inter-key interval plus backspace behavior as typing markers ([Dynamics in typewriting performance](https://pmc.ncbi.nlm.nih.gov/articles/PMC7537853/)).

**Profiles → Training coverage** shows evidence for key timing, rollover, corrections, and pauses within words, between words and at sentence boundaries. Counts describe support, not proven realism. **Learned pause habits** in My rhythm uses new context summaries only after at least 20 opportunities, three observed/retained pauses and two sessions in a category. It blends rates and durations with fallback behavior and keeps training modes separate. Existing current profiles remain useful without clearing; older samples lack these summaries and use fallback pauses until new recordings provide support. Legacy profiles stay locked.

## Validate the model

Open **Profiles → Validate rhythm** after saving four current sessions in the same mode. Choose a training context to see its ready count. Two later sessions are held out; earlier sessions alone train the temporary comparison profile. Overview compares Natural and My rhythm across paired trials using the same WPM and seeds, and includes a human-to-human reference. Detailed trials retains every comparison and observation count. Copy/Sprint text is only labeled matched when exact passage completion was recorded; partial or older unverified samples remain usable with that limitation. Live and Freewrite comparisons are unmatched.

The report provides median/MAD, KS and Wasserstein distances, rollover, autocorrelation, repair measures and sample counts. It exports as JSON. There is no “human percentage”: the Compose percentage now describes the variation setting. See [validation definitions and limitations](docs/VALIDATION.md). Tests establish internal correctness; fresh human traces are still needed before claiming measured human realism, and external-app delivery needs separate verification.

**Profiles → Check playback on this Mac** runs built-in overlap, correction and Unicode scenarios in a dedicated AppKit editor. It uses the production scheduler and event creation, with delivery addressed only to Typer's process. Results check text, missing/duplicate events, event order and modifier flags, and report receipt-time errors separately from event timestamps. Results stay in memory unless exported. This checks the local receiver; it does not certify external apps or physical keyboard latency. See the [follow-up research and priorities](docs/research/2026-09-07-follow-up.md).

## Notes

- Cross-application playback uses native Core Graphics keyboard events. There is no web view or browser runtime.
- Some protected fields, remote desktops, games, or apps that intercept keyboard events may not accept simulated keystrokes.
- The simulator plans repairs that restore the source text. The destination app's editing behavior, autocorrect, and keyboard handling can affect the delivered result.
- Human variation changes dwell, flight, bursts, and pauses only. Mistake frequency independently controls how many errors are injected and repaired.
- Generic Thought pauses have a 2.5% chance after each sentence ending. Supported learned sentence habits replace this occasional generic stall when enabled in My rhythm. Normal pauses last 2–5 seconds; Extended thought pauses use a skewed 2–45-second range. Any selected pause is included in the displayed time estimate, and the emergency stop remains responsive during it.
- **Sentence pauses** is a separate, optional Compose control. It waits after every detected sentence when more text follows, with a default random range of 2–10 seconds. Min and Max can each be set from 1–60 seconds; equal values give a fixed pause. It works with Thought pauses off and in Clean mode. At the same boundary, the longer of an existing pause and the sentence pause wins. Closing quotes and punctuation clusters stay together, and no extra wait is added at the end of the text. Detection uses Apple's [sentence tokenizer](https://developer.apple.com/documentation/naturallanguage/nltokenizer); unusual abbreviations and formatting can still be ambiguous.
- Sparkle checks the stable GitHub release feed by default. The optional Edge channel follows successful builds from `main`; both feeds require a valid Ed25519 signature.

### Local builds and update results

Settings → General shows the running build's origin and, for local builds, its build date and whether it includes unpublished changes. **Check now** reports whether a newer compatible published build exists, including the latest published version when available and the check time. Network and verification failures remain visible.

Checking and downloading do not require a restart. Automatic checks continue every six hours while Typer is open, and **Check now** checks immediately. Installing new app code requires a relaunch; Sparkle's update prompt handles installation and relaunching. Save unfinished training and copy any source text you want to keep before installing.

A local rebuild can retain the same `1.0.0-local.<commit>` label while containing new edits. Quit and reopen Typer after rebuilding to load those edits; save unfinished training and copy any source text you want to retain first.

Clean local builds use the HEAD commit timestamp as their internal build number, matching Edge for that commit. Rebuilding an older commit therefore still allows updates to newer Edge commits. Builds with uncommitted app source, resource, or build-file changes use the current time instead, protecting those edits from replacement by an older published build. The displayed build date always records when the local app was built. Distribution builds retain the version configured by the release workflow. Local changes become available through Edge only after they are pushed to `main` and the release workflow succeeds.

## Test

```bash
swift test
```
