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
5. Press **⌘ Esc** at any time to stop immediately.

While playback is running, Typer's own window shows the emergency hotkeys and a clickable **Stop typing** control. The overlay never covers the application receiving the text.

Open **Guide** in the top navigation or **Help → Typer Guide** for first-run steps, controls, training, measurement definitions, validation, permissions, updates, and troubleshooting. Small **?** icons beside controls and statistics show a quick explanation on hover; click one to keep the explanation open. **Train → How training works** opens the guide in a sheet so you can read it without leaving your current exercise.

Use **Train** in three ways: **Copy** learns exact errors and digraphs, **Freewrite** learns organic thought pauses, and **Sprint** learns fast bursts and recovery reflexes. The profiler measures dwell time, flight time, press-to-press digraph latency, timing variation, burst length, correction rate, detection delay, repair latency, and recurring substitutions. Profiles and samples stay in macOS user defaults on this Mac.

**Live capture** is an optional fourth mode for learning while you write in Google Docs or another application. It uses a listen-only event tap, never intercepts or delays the target application's input, pauses while macOS Secure Input is enabled, stops automatically after 15 minutes, and discards raw keystrokes when the session ends. Only derived timing and correction statistics are saved. Live capture requires the separate macOS **Input Monitoring** permission and never starts without an explicit click.

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

## Validate the model

Open **Profiles → Validate rhythm** after saving four new sessions in the same mode. Two later sessions are held out; earlier sessions alone train My rhythm. The report compares Natural and My rhythm with the held-out traces using the same WPM and seeds, and includes a human-to-human comparison. Copy uses its built-in reference passage; Live and Freewrite comparisons are explicitly labeled as unmatched text.

The report provides median/MAD, KS and Wasserstein distances, rollover, autocorrelation, repair measures and sample counts. It exports as JSON. There is no “human percentage”: the Compose percentage now describes the variation setting. See [validation definitions and limitations](docs/VALIDATION.md). Tests establish internal correctness; fresh human traces and a dedicated playback receiver are still needed before claiming measured human realism.

## Notes

- Cross-application playback uses native Core Graphics keyboard events. There is no web view or browser runtime.
- Some protected fields, remote desktops, games, or apps that intercept keyboard events may not accept simulated keystrokes.
- The simulator plans repairs that restore the source text. The destination app's editing behavior, autocorrect, and keyboard handling can affect the delivered result.
- Human variation changes dwell, flight, bursts, and pauses only. Mistake frequency independently controls how many errors are injected and repaired.
- Thought pauses have a 2.5% chance after each sentence ending. Normal pauses last 2–5 seconds; Extended thought pauses use a skewed 2–45-second range. Any selected pause is included in the displayed time estimate, and the emergency stop remains responsive during it.
- Sparkle checks the stable GitHub release feed by default. The optional Edge channel follows successful builds from `main`; both feeds require a valid Ed25519 signature.

### Local builds and update results

System setup shows the running build's origin and, for local builds, its build date and whether it includes unpublished changes. **Check now** reports whether a newer compatible published build exists, including the latest published version when available and the check time. Network and verification failures remain visible.

Checking and downloading do not require a restart. Automatic checks continue every six hours while Typer is open, and **Check now** checks immediately. Installing new app code requires a relaunch; Sparkle's update prompt handles installation and relaunching. Save unfinished training and copy any source text you want to keep before installing.

A local rebuild can retain the same `1.0.0-local.<commit>` label while containing new edits. Quit and reopen Typer after rebuilding to load those edits; save unfinished training and copy any source text you want to retain first. The updater uses the internal build number, so a fresh local build may be newer than the published Release or Edge build. Local changes become available through Edge only after they are pushed to `main` and the release workflow succeeds.

## Test

```bash
swift test
```
