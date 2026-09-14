import AppKit
import Foundation
import Carbon

struct BrowserProfileSnapshot: Codable {
    var profile: TypingProfile
    var settings: TypingSettings
    var samples: [TrainingSample]
    // Supplied explicitly by the launcher. The helper never opens UserDefaults.
    static let current: Self? = {
        let args = CommandLine.arguments
        let path = args.count >= 3 && ["--fixtures", "--validate-profile"].contains(args[1]) ? args[2] : args.count == 9 ? args[8] : ""
        guard !path.isEmpty, let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let snapshot = try? JSONDecoder().decode(Self.self, from: data), !snapshot.profile.isLegacy else { return nil }
        return snapshot
    }()
}

enum BrowserVariant: String, CaseIterable {
    case fixed, natural1, natural2, natural3, settingsNatural1, settingsNatural2, settingsNatural3, personal1, personal2, personal3
    var seed: UInt64? {
        switch self {
        case .fixed: return nil
        case .natural1, .settingsNatural1, .personal1: return 1
        case .natural2, .settingsNatural2, .personal2: return 2
        case .natural3, .settingsNatural3, .personal3: return 3
        }
    }
    var isPersonal: Bool { rawValue.hasPrefix("personal") }
    var usesSnapshot: Bool { isPersonal || rawValue.hasPrefix("settingsNatural") }
    var settings: TypingSettings {
        var settings = usesSnapshot ? BrowserProfileSnapshot.current!.settings : TypingSettings()
        settings.mode = isPersonal ? .personal : .natural
        return settings
    }
    var profile: TypingProfile { isPersonal ? BrowserProfileSnapshot.current!.profile : .baseline(wpm: settings.wpm) }
    var title: String {
        guard let seed else { return "Fixed delivery check" }
        return "\(isPersonal ? "My rhythm" : "Natural") · \(Int(settings.wpm)) WPM · seed \(seed)"
    }
}

enum BrowserFixture: String, CaseIterable {
    case plain, modifiers, overlap, corrections, lines, unicode, optionSymbols, accents, longForm, richText

    var title: String {
        switch self {
        case .plain: return "Everyday text"
        case .modifiers: return "Capitals & symbols"
        case .overlap: return "Overlapping keys"
        case .corrections: return "Editing & corrections"
        case .lines: return "Line breaks"
        case .unicode: return "Accents & Unicode"
        case .optionSymbols: return "Option symbols"
        case .accents: return "Keyboard accent sequences"
        case .longForm: return "Longer passage"
        case .richText: return "Rich-text editor"
        }
    }
    var instructions: String {
        switch self {
        case .corrections: return "Type cax, press Backspace, then type t. Type a space and blue; press Option–Backspace and type green."
        case .unicode: return "Type the passage using your normal input method. Different composition methods can produce different event sequences."
        default: return "Type the passage exactly, using your physical keyboard. Keep any corrections; the report will show them."
        }
    }
    var fixture: (text: String, plan: TypingPlan) {
        var events: [PlannedEvent] = []
        func type(_ text: String) {
            for ch in text {
                let kind: PlannedEventKind = ch == "\n" ? .enter : .character
                events.append(PlannedEvent(kind: kind, value: String(ch),
                    flight: self == .overlap ? -35 : 75, dwell: 90))
            }
        }
        let expected: String
        switch self {
        case .plain: expected = "the quick fox jumps over 12 lazy dogs."; type(expected)
        case .modifiers: expected = "Aa!? Zz:@ 12"; type(expected)
        case .overlap: expected = "fjfj fjfj abba baab"; type(expected)
        case .corrections:
            type("cax"); events.append(PlannedEvent(kind: .backspace, flight: 160, dwell: 90))
            type("t blue"); events.append(PlannedEvent(kind: .wordBackspace, flight: 160, dwell: 90))
            type("green"); expected = "cat green"
        case .lines: expected = "First line.\nSecond line."; type(expected)
        case .unicode: expected = "café — 🙂"; type(expected)
        case .accents: expected = "café déjà vu, naïve, mañana. ÉÜ àèìòù"; type(expected)
        case .longForm:
            expected = "At 9:30, Maya opened the café. She wrote: \"Two teas, one coffee—please.\" Outside, the rain had stopped; a cyclist waved and turned left. Tomorrow's list included 12 cups, 24 napkins, and a new sign."; type(expected)
        case .richText:
            expected = "A note from the café:\nBring 12 cups, two spoons, and fresh tea.\nThank you—see you at 9:30!"; type(expected)
        case .optionSymbols:
            expected = KeyboardMap.directCharacters.filter { $0.value.option }.keys.sorted().joined(); type(expected)
        }
        let normalized = KeyTimeline.normalized(events)
        return (expected, TypingPlan(events: normalized.events, duration: normalized.duration, repairs: 0, effectiveWPM: 60))
    }
    var variants: [BrowserVariant] {
        self == .plain ? BrowserVariant.allCases.filter { !$0.usesSnapshot || BrowserProfileSnapshot.current != nil } : [.fixed]
    }
    func plan(variant: BrowserVariant) -> TypingPlan {
        guard let seed = variant.seed else { return fixture.plan }
        // Settings/profile come from defaults or the explicit frozen snapshot.
        // The physical reference never supplies settings, seeds or training data.
        var random = SeededGenerator(seed: seed)
        return TypingEngine.generatePlan(text: fixture.text, settings: variant.settings, profile: variant.profile, using: &random)
    }
    func metadata(variant: BrowserVariant) -> [String: Any] {
        let plan = plan(variant: variant)
        let settings = variant.settings
        let settingsObject = (try? JSONSerialization.jsonObject(with: JSONEncoder().encode(settings))) ?? NSNull()
        return ["id": variant.rawValue, "title": variant.title, "duration": plan.duration,
                "generator": variant == .fixed ? "fixed-fixture" : "TypingEngine.generatePlan",
                "seed": variant.seed.map { $0 as Any } ?? NSNull(),
                "profile": variant == .fixed ? "none" : variant.isPersonal ? "saved-profile-snapshot" : "research-baseline",
                "profileSamples": variant.isPersonal ? variant.profile.sampleCount : 0,
                "profilePairs": variant.isPersonal ? variant.profile.evidence?.pairs.count ?? 0 : 0,
                "savedComposeMode": variant.usesSnapshot ? BrowserProfileSnapshot.current!.settings.mode.rawValue : "not used",
                "wpm": variant == .fixed ? NSNull() : settings.wpm, "variation": variant == .fixed ? NSNull() : settings.variation,
                "mistakeLevel": variant == .fixed ? NSNull() : settings.mistakeLevel,
                "settings": variant == .fixed ? NSNull() : settingsObject, "repairs": plan.repairs,
                "plannedEvents": plan.events.count, "physicalReferenceUsedForTraining": false]
    }
    var json: [String: Any] {
        ["id": rawValue, "title": title, "instructions": instructions,
         "text": fixture.text, "duration": fixture.plan.duration,
         "keyboardLayout": "com.apple.keylayout.US", "editorKind": self == .richText ? "contenteditable" : "textarea", "variants": variants.map { metadata(variant: $0) }]
    }
}

/// Temporary QA app: production scheduler/poster and built-in passages. An
/// optional explicit profile snapshot is read-only; no ProfileStore, capture
/// monitor, global shortcuts or persistent app preferences are loaded.
@MainActor
final class BrowserPlaybackDelegate: NSObject, NSApplicationDelegate {
    let stateURL: URL, resultURL: URL, fixture: BrowserFixture, runID: String, label: String, processTargeted: Bool
    let variant: BrowserVariant
    init(state: URL, result: URL, fixture: BrowserFixture, runID: String, label: String, processTargeted: Bool, variant: BrowserVariant) {
        self.stateURL = state; self.resultURL = result; self.fixture = fixture; self.runID = runID; self.label = label
        self.processTargeted = processTargeted
        self.variant = variant
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let stateURL = stateURL, resultURL = resultURL, fixture = fixture, runID = runID, label = label, processTargeted = processTargeted
        let variant = variant
        DispatchQueue.global(qos: .userInteractive).async {
            var failure: String?
            var sent = 0
            var actions: [[String: Any]] = []
            var postedKeys = Set<UInt16>()
            var targetPID: pid_t = 0
            let origin = ProcessInfo.processInfo.systemUptime
            let source = CGEventSource(stateID: .privateState)
            func attribute(_ element: AXUIElement, _ name: CFString) -> CFTypeRef? {
                var value: CFTypeRef?
                return AXUIElementCopyAttributeValue(element, name, &value) == .success ? value : nil
            }
            func checkFocus() -> Bool {
                guard AXIsProcessTrusted() else { failure = "Accessibility permission is unavailable for the native checker."; return false }
                guard KeyboardLayout.currentIdentifier() == "com.apple.keylayout.US" else {
                    failure = "The fixed native fixtures require the U.S. keyboard layout."; return false
                }
                guard let data = try? Data(contentsOf: stateURL),
                      let state = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      state["runID"] as? String == runID, state["active"] as? Bool == true,
                      let heartbeat = state["heartbeat"] as? Double,
                      abs(Date().timeIntervalSince1970 * 1000 - heartbeat) < 1000 else {
                    failure = "Recording stopped or the local page stopped responding."; return false
                }
                guard let app = NSWorkspace.shared.frontmostApplication, app.bundleIdentifier == "com.apple.Safari" else {
                    failure = "Safari lost foreground focus."; return false
                }
                let application = AXUIElementCreateApplication(app.processIdentifier)
                AXUIElementSetMessagingTimeout(application, 0.25)
                guard let value = attribute(application, kAXFocusedUIElementAttribute as CFString),
                      CFGetTypeID(value) == AXUIElementGetTypeID() else {
                    failure = "Cannot verify the focused editor."; return false
                }
                let focused = unsafeBitCast(value, to: AXUIElement.self)
                // Safari content can be hosted in a WebContent process. Verify
                // the unique page-owned label as well as foreground Safari.
                let role = attribute(focused, kAXRoleAttribute as CFString) as? String
                let labels = [kAXDescriptionAttribute, kAXTitleAttribute, kAXHelpAttribute].compactMap {
                    attribute(focused, $0 as CFString) as? String
                }
                guard role == "AXTextArea", labels.contains(label) else {
                    failure = "Focus left the dedicated test editor (role: \(role ?? "unknown"))."; return false
                }
                targetPID = app.processIdentifier
                return true
            }
            // Safari can expose the previous document's AX node briefly after
            // navigation. Wait without posting until the new editor is verified.
            let readyDeadline = ProcessInfo.processInfo.systemUptime + 2
            var ready = checkFocus()
            while !ready && ProcessInfo.processInfo.systemUptime < readyDeadline {
                Thread.sleep(forTimeInterval: 0.05)
                ready = checkFocus()
            }
            if ready { failure = nil }
            let session = PlaybackSession { action in
                if action.isDown && !checkFocus() { return false }
                // A focus guard can reject a down before it reaches the OS.
                // Do not leak the scheduler's defensive cleanup up in that case.
                if !action.isDown && !postedKeys.contains(action.code) { return true }
                guard let event = KeyboardEventPoster.make(action, source: source) else {
                    failure = "A keyboard event could not be created."; return false
                }
                // Default matches TypingController. The legacy HID route is an
                // explicit diagnostic control, recorded in every result.
                if processTargeted { KeyboardEventPoster.post(event, to: targetPID) }
                else { event.post(tap: .cghidEventTap) }
                if action.isDown { postedKeys.insert(action.code) } else { postedKeys.remove(action.code) }
                sent += 1
                actions.append(["code": action.code, "down": action.isDown, "shift": action.shift,
                                "option": action.option, "offset": (ProcessInfo.processInfo.systemUptime - origin) * 1000])
                return true
            }
            let outcome: PlaybackSession.Outcome = ready ? session.run(plan: fixture.plan(variant: variant)) : .failed
            let result: [String: Any] = ["runID": runID, "completed": outcome == .complete,
                "error": failure ?? "", "sentActions": sent, "actions": actions, "variant": fixture.metadata(variant: variant),
                "route": processTargeted ? "CGEvent / postToPid" : "CGEvent / cghidEventTap", "system": ProcessInfo.processInfo.operatingSystemVersionString]
            if let data = try? JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]) {
                try? data.write(to: resultURL, options: .atomic)
            }
            DispatchQueue.main.async { NSApp.terminate(nil) }
        }
    }
}

@main
struct BrowserPlaybackCheck {
    @MainActor static func main() {
        let args = CommandLine.arguments
        if args.count == 4 && args[1] == "--validate-profile", let snapshot = BrowserProfileSnapshot.current {
            let report = TypingValidation.evaluate(samples: snapshot.samples, mode: .copy)
            let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try! encoder.encode(report).write(to: URL(fileURLWithPath: args[3])); return
        }
        if args.count == 3 && args[1] == "--fixtures" {
            let data = try! JSONSerialization.data(withJSONObject: BrowserFixture.allCases.map(\.json), options: [.prettyPrinted, .sortedKeys])
            print(String(decoding: data, as: UTF8.self)); return
        }
        guard args.count == 9, let fixture = BrowserFixture(rawValue: args[3]),
              let variant = BrowserVariant(rawValue: args[7]), fixture.variants.contains(variant) else { return }
        let app = NSApplication.shared
        let delegate = BrowserPlaybackDelegate(state: URL(fileURLWithPath: args[1]), result: URL(fileURLWithPath: args[2]),
                                               fixture: fixture, runID: args[4], label: args[5], processTargeted: args[6] != "hid", variant: variant)
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }
}
