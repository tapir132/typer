# Typer: realism that can be measured

September 6, 2026 | Research and implementation review

Audience: Typer's developer and reviewers. Scope: local native macOS typing simulation, personal timing, correction behavior and validation. Assumptions: exact final source text remains required; Live capture remains opt-in; current profiles must remain readable. Publishing, notarization, device detection and neural modeling are outside this pass.

## The research changes the implementation

The strongest improvement is a physical timeline plus trustworthy measurements. Adding independent random delays cannot reproduce overlapping keys, and an attractive percentage cannot establish realism. Typer now supports rollover, learns paired timing observations with evidence-based backoff, separates observed repairs from inferred intent, and offers held-out local comparisons.

The central measurement rule is simple: hold is down-to-up; press interval is down-to-next-down; signed flight is up-to-next-down. Thus, press interval equals preceding hold plus signed flight. Negative signed flight is valid. This matches the [CMU benchmark definitions](https://www.cs.cmu.edu/~keystroke/), rather than relying on the ambiguous term "flight."

## What is implemented

- One shared playback timeline permits overlapping character keys. Repeated physical keys, editing commands, Unicode fallback and modifier changes create conservative barriers.
- Joint empirical hold/interval observations refine a positive, log-normal baseline. Rare exact pairs back off through QWERTY transition classes and pooled personal timing.
- Optional schema additions preserve v1 profiles. Observation counts and capped session contributions replace equal-weight session confidence.
- Corrections add omissions with cursor insertion, extra characters and word deletion. Live learns categories and deletion runs without inventing intended characters.
- Profiles exposes a local validation report and JSON export. The former "human" percentage now describes variation intensity.

## What this establishes

Deterministic regression tests verify internal behavior, including text equivalence, overlap, modifier release, cancellation, persistence compatibility and statistical calculations. Controlled synthetic fixtures verify that personal evidence can improve hold and rollover fit. Fresh held-out human sessions and a receiver measuring actual delivered events are still needed for a claim of improved human realism.

---page---

# Physical timing: evidence and limits

## Rollover is real, but no single ratio is universal

The [136-million-keystroke study](https://userinterfaces.aalto.fi/136Mkeystrokes/resources/chi-18-analysis.pdf) observed substantial rollover, with major differences between typists and speed groups. It was a large, self-selected online transcription sample. Its cohort averages are useful evidence that serial press/release playback is incomplete; they are not universal calibration targets for every person or WPM.

Typer therefore derives overlap from the relationship between a preceding hold and the following press interval. It does not insert overlap merely to hit a published percentage. The timeline compiler can reduce a sampled overlap to preserve physical-key and editing semantics. Reports measure the resulting compiled timeline.

[timeline]

## Positive distributions apply to the right quantities

[González and colleagues' distribution study](https://pmc.ncbi.nlm.nih.gov/articles/PMC8606350/) favors log-logistic families and also finds log-normal a strong candidate. Critically, its "flight" variable is down-to-down, not signed up-to-down. It does not justify a positive-only distribution for signed flight. Its richer fits also required substantially more observations than a one-off letter pair.

Typer uses positive log-normal fallback timing and bounded paired empirical observations. Signed flight is derived afterward. This avoids fitting a three-parameter distribution to sparse samples. The numerical spreads, support bounds and shrinkage constants remain engineering choices requiring calibration.

## Finger classes are assumptions

[Feit, Weir and Oulasvirta's movement study](https://userinterfaces.aalto.fi/how-we-type/resources/HowWeType_CHI16.pdf) found varied finger-to-key mappings and anticipatory movement among everyday typists. Keyboard event logs do not reveal the actual finger used. Typer's same-finger, same-hand and alternating-hand classes explicitly assume conventional US QWERTY typing; exact personal pairs can override that fallback when evidence is stronger.

---page---

# Personal evidence, repairs and privacy

## Learn where observations are strong

The [partially observable HMM keystroke study](https://vmonaco.com/papers/The%20partially%20observable%20hidden%20Markov%20model%20and%20its%20application%20to%20keystroke%20dynamics.pdf) provides a precedent for smoothing rare context estimates toward better-supported marginals. It supports the principle, not Typer's particular formula or constants.

Typer now refines timing through pooled personal observations, a transition class, then an exact pair. Valid observation counts control each refinement. Seeded reservoir sampling bounds storage without systematically selecting the same position in a periodic typing pattern. A session contributes at most 128 observations per merged pool, so a short session and a long session have different influence while one long session cannot contribute without limit.

Global scalar summaries use capped observation weights. Hold, repair and detection parameters also use evidence specific to those features. Unknown legacy evidence is treated cautiously. Training mode is retained, and the active merge uses recent samples from the newly saved mode.

## Model an editing episode, not imagined intent

[Pinet and Nozari's correction experiment](https://journalofcognition.org/articles/10.5334/joc.202), published in 2022, supports distinguishing immediate and delayed repair behavior. Its detailed timing differences were confined to repair intervals in a difficult, time-limited single-word task. That does not establish universal error proportions or a mandatory post-repair slowdown.

Typer adds omission-and-insertion episodes, extra characters and Option-Backspace word repair. Existing transpositions, duplicate characters, selections and delayed retyping remain. Generated mistakes still resolve to source text in the model. Coarse observed edit-category proportions can influence strategy selection; they do not identify a user's full editing intent.

## Privacy remains explicit

Live capture still requires an explicit start, uses a listen-only tap, ignores Typer's own window and pauses for macOS Secure Input. The 15-minute limit now starts at session activation, including idle time. Focus changes, clicks, unsupported chords and capture interruptions break timing sequences rather than creating false digraphs across them.

Raw Live records are discarded at stop. Saved data contain bounded derived timings, pair/class statistics and edit categories. Letter-pair usage remains personal information, even without document text. Live deletion-run length is reported as an observation; it is no longer mislabeled as error detection distance. One-click deletion clears profiles and samples.

---page---

# Validation: compare untouched sessions

## The local protocol

Save at least four new sessions in one training mode. The latest two eligible sessions remain untouched while up to five earlier sessions fit My rhythm. Natural and My rhythm use the same requested WPM and seeds 17, 41 and 89. The report also compares the two human sessions, giving the user context for ordinary within-person variation. These minimum counts are practical defaults, not research-established sufficiency thresholds.

The [CMU evaluation procedure](https://www.cs.cmu.edu/~keystroke/) separates earlier training observations from later evaluation observations. Typer applies that separation at whole-session level. Further tuning after inspecting a report requires additional fresh sessions; repeated inspection of the same holdouts is not independent confirmation.

Copy/Sprint can generate their built-in reference passage. Live/Freewrite use a standard passage because their original text is unavailable. Those trials are explicitly marked unmatched: different character and punctuation frequencies may explain a timing difference.

## Read the measurements directly

- Median and median absolute deviation describe timing center and spread.
- [KS distance](https://docs.scipy.org/doc/scipy/reference/generated/scipy.stats.ks_2samp.html) is the largest absolute separation between empirical cumulative distributions. Smaller means closer marginal distributions. No p-value or humanity probability is reported.
- [Wasserstein-1](https://docs.scipy.org/doc/scipy/reference/generated/scipy.stats.wasserstein_distance.html) integrates that separation. Timing distances retain millisecond units; burst/deletion distances use keys or actions.
- Rollover ratio, overlap durations, transition classes, exact pairs, multi-key bursts, pauses, deletion runs and pre-deletion intervals expose different aspects of behavior.
- Adjacent-interval correlation checks local continuity. Reordering a trace can preserve all marginal distributions while changing this measure.

## Missing evidence stays missing

The report shows observed-pair counts separately from retained distribution counts, plus missing holds. Empty metrics and undefined correlations remain unavailable. Holds must be 10-500 ms; motor press intervals 15-2500 ms; pauses 1000-60000 ms. Multi-key bursts use a 310 ms boundary. Filtering, bounds and small samples constrain interpretation. Keystroke dependence and clock quantization make ordinary independent-sample inference questionable; these reports are descriptive diagnostics.

---page---

# Delivery, remaining evidence and next experiment

## Verified implementation

The regression suite covers exact final text across 500 original seed/text combinations, positive/zero/negative flight, modifier and correction barriers, overlap cancellation, failed-output cleanup, migration-compatible decoding, capped evidence weighting, pathological values, distribution metrics, temporal holdout separation and responsive long-input generation. The native app bundle is built locally; there is no published release in this pass.

The reproducible implementation is in KeyTimeline.swift, TimingEvidence.swift and TypingValidation.swift, with integration in the existing controller, engine, training and profile views. The repository's docs/VALIDATION.md specifies the protocol, definitions and practical limits. Profiles - Validate rhythm produces the local report and optional JSON export.

## What remains unproven

No new human sessions were recorded for this task. The controlled fixture improvement is a software check, not a population result. The model's baseline distributions, bounds, shrinkage weights and error proportions have not been optimized against an independent human cohort. Finger assignments and physical key mapping assume US QWERTY. Device and layout adaptation remain future work.

[Apple's keyboard-event documentation](https://developer.apple.com/documentation/coregraphics/cgevent/init(keyboardeventsource:virtualkey:keydown:)) requires explicit modifier events; the output ledger implements them. [Apple's Unicode documentation](https://developer.apple.com/documentation/coregraphics/cgevent/keyboardsetunicodestring(stringlength:unicodestring:)) also warns that applications may use their own key translation. Model text-equivalence tests and a compiled timeline do not prove that every external editor honors emitted events or realizes their exact timing.

## The next useful experiment

Collect six to eight Copy sessions on the same keyboard and layout, with natural corrections, across more than one sitting. Freeze settings before evaluation. Compare the two later held-out sessions across all seeds, inspect both timing and repair measures, and compare differences with human-to-human variation. Repeat with additional untouched sessions if tuning follows. Then use a dedicated local receiver to record delivered key-down/up timestamps and final text, including mixed case, punctuation, Unicode, word repairs and emergency cancellation.

## External benchmarks need care

The [Mendeley human/synthetic benchmark](https://data.mendeley.com/datasets/mzm86rcxxd/2) uses "FT" for press-to-press intervals, replaces timings above 1500 ms with -1 and has CC BY NC 3.0 data terms. Its missing sentinel is not negative flight, and its censored tail cannot validate long thinking pauses. [Aalto's project page](https://userinterfaces.aalto.fi/136Mkeystrokes/) also specifies research/noncommercial data use. No research dataset or derived trained artifact is bundled here.

Research stopped after the key definitions, implementation mechanisms, metric interpretation and benchmark limits were reconciled. More broad literature searches cannot replace fresh human traces and a measured playback receiver.

---page---

# Source notes

Primary research and official documentation were reviewed on September 6, 2026. Links open the supporting sources; no source datasets are embedded in this report or bundled with the app.

[Comparing Anomaly-Detection Algorithms for Keystroke Dynamics: benchmark supplement](https://www.cs.cmu.edu/~keystroke/). Kevin Killourhy and Roy Maxion, Carnegie Mellon University, DSN 2009. Timing identities and temporal evaluation procedure.

[Observations on Typing from 136 Million Keystrokes](https://userinterfaces.aalto.fi/136Mkeystrokes/resources/chi-18-analysis.pdf). Vivek Dhakal, Anna Maria Feit, Per Ola Kristensson and Antti Oulasvirta, CHI 2018. Rollover and typing variation. [Authors' project and data terms](https://userinterfaces.aalto.fi/136Mkeystrokes/).

[On the shape of timings distributions in free-text keystroke dynamics profiles](https://pmc.ncbi.nlm.nih.gov/articles/PMC8606350/). Nahuel González, Enrique P. Calot, Jorge S. Ierache and Waldo Hasperué, Heliyon, November 17, 2021. Full text also verified through Europe PMC XML.

[How We Type: Movement Strategies and Performance in Everyday Typing](https://userinterfaces.aalto.fi/how-we-type/resources/HowWeType_CHI16.pdf). Anna Maria Feit, Daryl Weir and Antti Oulasvirta, CHI 2016. Personal finger mappings and anticipatory movement.

[The partially observable hidden Markov model and its application to keystroke dynamics](https://vmonaco.com/papers/The%20partially%20observable%20hidden%20Markov%20model%20and%20its%20application%20to%20keystroke%20dynamics.pdf). John V. Monaco and Charles C. Tappert, Pattern Recognition 76, 2018; online November 21, 2017. Context smoothing, section 3.7.

[Correction Without Consciousness in Complex Tasks: Evidence from Typing](https://journalofcognition.org/articles/10.5334/joc.202). Svetlana Pinet and Nazbanou Nozari, Journal of Cognition, January 7, 2022. Publisher metadata and Europe PMC full text reconciled.

[ks_2samp reference](https://docs.scipy.org/doc/scipy/reference/generated/scipy.stats.ks_2samp.html) and [wasserstein_distance reference](https://docs.scipy.org/doc/scipy/reference/generated/scipy.stats.wasserstein_distance.html). SciPy community, official online documentation, accessed September 6, 2026. Distance definitions and inferential assumptions.

[Dataset of Human-written and Synthesized Samples of Free-Text Keystroke Dynamics to Evaluate Liveness Detection Methods](https://data.mendeley.com/datasets/mzm86rcxxd/2). Nahuel González and Enrique Calot, Mendeley Data, version 2, September 13, 2022. Preprocessing and CC BY NC 3.0 data terms; associated Data in Brief article published in 2023.

[CGEvent keyboard event initializer](https://developer.apple.com/documentation/coregraphics/cgevent/init(keyboardeventsource:virtualkey:keydown:)) and [keyboardSetUnicodeString](https://developer.apple.com/documentation/coregraphics/cgevent/keyboardsetunicodestring(stringlength:unicodestring:)). Apple, Core Graphics documentation, accessed September 6, 2026. Modifier requirements and application translation limitations.
