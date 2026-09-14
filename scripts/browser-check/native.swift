import AppKit
import Foundation
import Carbon

enum BrowserFixture: String, CaseIterable {
    case plain, modifiers, overlap, corrections, lines, unicode, optionSymbols

    var title: String {
        switch self {
        case .plain: return "Everyday text"
        case .modifiers: return "Capitals & symbols"
        case .overlap: return "Overlapping keys"
        case .corrections: return "Editing & corrections"
        case .lines: return "Line breaks"
        case .unicode: return "Accents & Unicode"
        case .optionSymbols: return "Option symbols"
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
        case .optionSymbols: expected = "–—“”‘’…•°©®™£€"; type(expected)
        }
        let normalized = KeyTimeline.normalized(events)
        return (expected, TypingPlan(events: normalized.events, duration: normalized.duration, repairs: 0, effectiveWPM: 60))
    }
    var json: [String: Any] {
        ["id": rawValue, "title": title, "instructions": instructions,
         "text": fixture.text, "duration": fixture.plan.duration,
         "keyboardLayout": "com.apple.keylayout.US"]
    }
}

/// Temporary QA app: production scheduler/poster, fixed fixtures only. No user
/// profiles, capture monitors, global shortcuts or persistent app preferences.
@MainActor
final class BrowserPlaybackDelegate: NSObject, NSApplicationDelegate {
    let stateURL: URL, resultURL: URL, fixture: BrowserFixture, runID: String, label: String, processTargeted: Bool
    init(state: URL, result: URL, fixture: BrowserFixture, runID: String, label: String, processTargeted: Bool) {
        self.stateURL = state; self.resultURL = result; self.fixture = fixture; self.runID = runID; self.label = label
        self.processTargeted = processTargeted
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let stateURL = stateURL, resultURL = resultURL, fixture = fixture, runID = runID, label = label, processTargeted = processTargeted
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
                if let input = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue(),
                   let property = TISGetInputSourceProperty(input, kTISPropertyInputSourceID) {
                    let identifier = Unmanaged<CFString>.fromOpaque(property).takeUnretainedValue() as String
                    guard identifier == "com.apple.keylayout.US" else {
                        failure = "The fixed native fixtures require the U.S. keyboard layout."; return false
                    }
                } else { failure = "Cannot verify the keyboard layout."; return false }
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
            let outcome: PlaybackSession.Outcome = ready ? session.run(plan: fixture.fixture.plan) : .failed
            let result: [String: Any] = ["runID": runID, "completed": outcome == .complete,
                "error": failure ?? "", "sentActions": sent, "actions": actions,
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
        if args.count == 2 && args[1] == "--fixtures" {
            let data = try! JSONSerialization.data(withJSONObject: BrowserFixture.allCases.map(\.json), options: [.prettyPrinted, .sortedKeys])
            print(String(decoding: data, as: UTF8.self)); return
        }
        guard (args.count == 6 || args.count == 7), let fixture = BrowserFixture(rawValue: args[3]) else { return }
        let app = NSApplication.shared
        let delegate = BrowserPlaybackDelegate(state: URL(fileURLWithPath: args[1]), result: URL(fileURLWithPath: args[2]),
                                               fixture: fixture, runID: args[4], label: args[5], processTargeted: args.last != "hid")
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }
}
