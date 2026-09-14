# Browser input validation — September 13, 2026

## Objective

Measure the events a regular Safari page receives from Typer's production keyboard event creation and scheduler. Compare an explicitly recorded physical-keyboard sample with playback, and fix demonstrated delivery defects. A passing report establishes only the properties and scenarios tested; it does not certify human input or universal indistinguishability.

## Implementation sequence

1. Add a local-only browser editor that records keydown/up, beforeinput/input, composition, selection and focus boundaries, with explicit start/stop, bounded memory, and optional JSON export. Label physical, Typer and browser-automation samples separately.
2. Add deterministic production playback fixtures for text, modifiers, overlap, corrections, line breaks and Unicode. Use the normal Core Graphics HID posting route into a regular Safari window, with an Accessibility focus check before each key-down and cancellation on focus loss. Never send arbitrary text or record another app.
3. Compare final text, event balance/order, key/code/location/modifier properties, trusted-event values and descriptive hold/flight intervals. Block conclusions from incomplete, interrupted, pasted or mismatched samples. Separate structural differences from statistical timing differences and supported layout limitations.
4. Exercise the page with browser automation, run native Safari delivery checks, add regressions for demonstrated production defects, and rerun existing playback/shortcut checks after any shared event-path change.
5. Request one short physical sample in the local page. If none is supplied, finish the harness and automated checks while leaving the physical-comparison result explicitly pending.

## Research constraints

- [DOM's isTrusted definition](https://dom.spec.whatwg.org/#dom-event-istrusted) describes browser dispatch, not physical provenance.
- [UI Events](https://www.w3.org/TR/uievents/) defines the exposed keyboard/input properties and ordering, with composition and platform-specific behavior.
- [WebDriver](https://www.w3.org/TR/webdriver/#actions) deliberately generates trusted input. It is an automated control, never a physical-keyboard reference.
- [Safari WebDriver](https://developer.apple.com/documentation/safari-developer-tools/webdriver) places a glass pane over automation windows. Use a normal Safari window for native delivery. Remote Automation is disabled on this Mac; the normal-window harness does not require changing it.
- [CGEvent source process IDs](https://developer.apple.com/documentation/coregraphics/cgeventfield/eventsourceunixprocessid) remain observable to native code. Do not overwrite provenance or present a browser-only report as OS-level equivalence.

## Acceptance

- One documented command builds and launches the local check without modifying installed Typer, user profiles, TCC, or Safari settings.
- Recording ends on stop, blur, hidden page, timeout or size limit. Export is explicit. The server binds loopback and serves only its bundled assets behind a session token.
- Reports retain run provenance, browser/system/layout context, limitations, sample sizes and specific differences; no human percentage or pass from missing data.
- Automated comparison tests cover identical traces, missing/releases/repeats, modifier differences, malformed/imported data, interrupted runs, paste/composition and inadequate timing evidence.

## Implementation decisions from measurements

- The first six global-HID Safari fixtures delivered the expected text. Unicode payloads such as an em dash appeared with `code: KeyA`; its release appeared as `key: a`. Added direct U.S. Option-layer mappings for fourteen common symbols. A regression translates every mapping through Apple's installed U.S. layout with `UCKeyTranslate`, requiring the intended character and no unfinished dead-key state.
- The expanded symbol-only HID fixture exposed missing ordinary key events despite modifier events reaching Safari. Some runs also changed focus. Plain text and a mixed Unicode passage remained successful. A process-addressed control delivered the entire symbol fixture. This supports changing the delivery route; it does not identify a particular remapper, app or OS component as the cause. Existing keyboard settings were not changed.
- Production delivery now uses `CGEvent.postToPid` for the selected application, including cleanup releases. The app-switch pause behavior remains. The local harness defaults to the same route and retains `--global-hid` only as a labelled comparison control. See [Apple's process-addressed API](https://developer.apple.com/documentation/coregraphics/cgevent/posttopid(_:)) and [global-post tap behavior](https://developer.apple.com/documentation/coregraphics/cgevent/post(tap:)).
- Safari accessibility queries can fail or expose stale editor identity around navigation. The native checker waits without posting for its exact editor label, then rechecks before each key-down. Its additional AX checks are measurement overhead, not evidence of hardware latency.
- A physical reference was requested separately. Browser automation, native fixtures and matching `isTrusted` values cannot supply that missing evidence.
