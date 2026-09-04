# Typer

Typer is a fully native SwiftUI macOS app that performs pasted text with human cadence. It supports selectable WPM, independent dwell and flight time, per-digraph timing, punctuation and thinking pauses, adjacent-key slips, transpositions, duplicate keys, whole-word substitutions, immediate backspaces, delayed repairs, fatigue drift, and learned personal typing profiles.

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

Use **Train** in three ways: **Copy** learns exact errors and digraphs, **Freewrite** learns organic thought pauses, and **Sprint** learns fast bursts and recovery reflexes. The profiler measures dwell time, flight time, press-to-press digraph latency, timing variation, burst length, correction rate, detection delay, repair latency, and recurring substitutions. Profiles and samples stay in macOS user defaults on this Mac.

### Mistakes and corrections during training

Correct mistakes in all three modes exactly as you naturally would. Do not deliberately manufacture typos, rush a correction, or leave an error behind just to give the model more data.

- **Copy:** Type the passage accurately and fix genuine mistakes using your normal correction behavior.
- **Freewrite:** Compose fresh text in the box. Pause, revise, delete words, and correct mistakes naturally.
- **Sprint:** Type quickly, but still correct a mistake when that is your normal reflex.

Corrections are useful training data: Typer records which mistakes occur, how many characters you type before noticing them, and whether you backspace or revise an earlier word. If you genuinely would not notice a particular mistake, leaving it is also representative—just do not make that choice artificially for the test.

## How the model works

The personal mode samples from the distributions it recorded instead of applying one random delay to every key. Specific letter pairs can be fast or awkward, dwell and flight remain separate, neighboring timings drift together in short motor patterns, sentences create larger pauses, and longer runs slowly change cadence. Error generation reuses the typist's observed substitutions and detection delay when enough samples exist.

The approach is informed by the [CMU keystroke-dynamics benchmark](https://www.cs.cmu.edu/~keystroke/), research showing that immediate and delayed repairs have measurably different timing ([Correction Without Consciousness in Complex Tasks](https://pmc.ncbi.nlm.nih.gov/articles/PMC8740635/)), and field research using inter-key interval plus backspace behavior as typing markers ([Dynamics in typewriting performance](https://pmc.ncbi.nlm.nih.gov/articles/PMC7537853/)).

## Notes

- Cross-application playback uses native Core Graphics keyboard events. There is no web view or browser runtime.
- Some protected fields, remote desktops, games, or apps that intercept keyboard events may not accept simulated keystrokes.
- The simulator always repairs generated mistakes so the final text matches the source.
- Human variation changes dwell, flight, bursts, and pauses only. Mistake frequency independently controls how many errors are injected and repaired.
- Extended thought pauses optionally allow rare sentence-level stalls up to 45 seconds; the emergency stop remains responsive during them.
- Sparkle checks the stable GitHub release feed by default. The optional Edge channel follows successful builds from `main`; both feeds require a valid Ed25519 signature.

## Test

```bash
swift test
```
