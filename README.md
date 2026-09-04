# Typer

Typer is a fully native SwiftUI macOS app that performs pasted text with human cadence. It supports selectable WPM, independent dwell and flight time, per-digraph timing, punctuation and thinking pauses, adjacent-key slips, transpositions, duplicate keys, whole-word substitutions, immediate backspaces, delayed repairs, fatigue drift, and learned personal typing profiles.

## Run it

```bash
swift run Typer
```

To build a normal, ad-hoc-signed `.app` bundle:

```bash
chmod +x scripts/build-app.sh
./scripts/build-app.sh
open .build/Typer.app
```

On first use, open Typer's settings and enable Accessibility permission in **System Settings → Privacy & Security → Accessibility**. If you run the app through Terminal during development, macOS may list Terminal as the process that needs permission.

## Workflow

1. Paste or write source text in **Compose**.
2. Choose WPM and realism settings.
3. Click **Arm typing**.
4. During the five-second countdown, focus any editable field in another app.
5. Press **⌘ Esc** at any time to stop immediately.

Use **Train** in three ways: **Copy** learns exact errors and digraphs, **Freewrite** learns organic thought pauses, and **Sprint** learns fast bursts and recovery reflexes. The profiler measures dwell time, flight time, press-to-press digraph latency, timing variation, burst length, correction rate, detection delay, repair latency, and recurring substitutions. Profiles and samples stay in macOS user defaults on this Mac.

## How the model works

The personal mode samples from the distributions it recorded instead of applying one random delay to every key. Specific letter pairs can be fast or awkward, dwell and flight remain separate, neighboring timings drift together in short motor patterns, sentences create larger pauses, and longer runs slowly change cadence. Error generation reuses the typist's observed substitutions and detection delay when enough samples exist.

The approach is informed by the [CMU keystroke-dynamics benchmark](https://www.cs.cmu.edu/~keystroke/), research showing that immediate and delayed repairs have measurably different timing ([Correction Without Consciousness in Complex Tasks](https://pmc.ncbi.nlm.nih.gov/articles/PMC8740635/)), and field research using inter-key interval plus backspace behavior as typing markers ([Dynamics in typewriting performance](https://pmc.ncbi.nlm.nih.gov/articles/PMC7537853/)).

## Notes

- Cross-application playback uses native Core Graphics keyboard events. There is no web view or browser runtime.
- Some protected fields, remote desktops, games, or apps that intercept keyboard events may not accept simulated keystrokes.
- The simulator always repairs generated mistakes so the final text matches the source.

## Test

```bash
swift test
```
