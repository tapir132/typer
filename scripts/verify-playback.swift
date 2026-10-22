import AppKit
import ApplicationServices
import SwiftUI

/// Run in a real application event loop, independently of the user's Typer app
/// and its profiles. Every generated event is addressed only to this process.
@MainActor
final class PlaybackVerificationDelegate: NSObject, NSApplicationDelegate {
    var window: NSWindow!
    var controller = PlaybackCheckController(requiresFocus: false)
    let output: URL
    let lifecycle = TyperAppDelegate()
    var quitObserver: NSObjectProtocol?
    var savedOnQuit: TypingController?
    init(output: URL) { self.output = output }

    func applicationDidFinishLaunching(_ notification: Notification) {
        lifecycle.applicationDidFinishLaunching(notification)
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 820, height: 730),
                          styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Typer playback verification"
        window.isReleasedWhenClosed = false
        let host = NSHostingView(rootView: PlaybackCheckView(controller: controller).preferredColorScheme(.dark))
        host.sizingOptions = []
        window.contentView = host
        window.center()
        window.orderBack(nil)
        Task { @MainActor in
            do {
                try await Task.sleep(for: .milliseconds(500))
                for scenario in PlaybackCheckScenario.allCases {
                    controller.scenario = scenario
                    controller.start()
                    guard controller.isRunning else {
                        throw Failure.message("\(controller.status) Active: \(NSApp.isActive), key: \(window.isKeyWindow), visible: \(window.isVisible), can key: \(window.canBecomeKey), receiver attached: \(controller.receiver?.window === window)")
                    }
                    let deadline = Date().addingTimeInterval(30)
                    while controller.isRunning && Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
                    guard let report = controller.report else { throw Failure.message("No report before the 30-second deadline.") }
                    let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                    try encoder.encode(report).write(to: output.appendingPathComponent("\(scenario.rawValue).json"))
                    try await Task.sleep(for: .milliseconds(100))
                    host.layoutSubtreeIfNeeded()
                    if let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
                        host.cacheDisplay(in: host.bounds, to: bitmap)
                        try bitmap.representation(using: .png, properties: [:])?.write(to: output.appendingPathComponent("\(scenario.rawValue).png"))
                    }
                    guard report.integrityPassed else {
                        throw Failure.message("\(scenario.rawValue): received \(report.receivedText.debugDescription); missing \(report.missingEvents); order \(report.outOfOrderEvents); flags \(report.modifierMismatches); \(report.interruption ?? "no interruption")")
                    }
                }
                for control in ["pause", "cancel", "failure"] { try await verifyCompositionControl(control) }
                for control in ["selection", "accent"] { try await verifySavedContinuation(control) }
                try await prepareQuitCheckpointCheck()
                try JSONSerialization.data(withJSONObject: ["passed": true, "scenarios": 3, "compositionControls": ["pause", "cancel", "failure"], "savedContinuations": ["selection", "accent"], "quitCheckpoint": "quit-saved-run.json"], options: [.prettyPrinted]).write(to: output.appendingPathComponent("result.json"))
            } catch {
                try? JSONSerialization.data(withJSONObject: ["passed": false, "error": String(describing: error)], options: [.prettyPrinted]).write(to: output.appendingPathComponent("result.json"))
            }
            controller.close()
            window.close()
            // Match a menu Quit: enter via the AppKit run loop. A Swift task
            // or main-queue block holds its executor across terminateLater's
            // nested loop and would starve the asynchronous save preflight.
            NSApp.perform(#selector(NSApplication.terminate(_:)), with: nil, afterDelay: 0)
        }
    }

    private func verifyCompositionControl(_ control: String) async throws {
        guard let receiver = controller.receiver else { throw Failure.message("No composition receiver.") }
        receiver.string = ""; receiver.setSelectedRange(NSRange(location: 0, length: 0))
        let marker = PlaybackCheckRouter.signature | (Int64(UInt32.random(in: 1...UInt32.max)) << 16)
        let source = CGEventSource(stateID: .privateState)
        let normalized = KeyTimeline.normalized("éa".map { PlannedEvent(kind: .character, value: String($0), flight: 100, dwell: 100) })
        let plan = TypingPlan(events: normalized.events, duration: normalized.duration, repairs: 0, effectiveWPM: 0)
        let session = PlaybackSession { action in
            if control == "failure" && action.isDown && action.eventIndex == 0 { return false }
            guard let event = KeyboardEventPoster.make(action, source: source, marker: marker) else { return false }
            KeyboardEventPoster.post(event, to: ProcessInfo.processInfo.processIdentifier); return true
        }
        var triggered = false, finished = false, outcome: PlaybackSession.Outcome?
        guard PlaybackCheckRouter.shared.acquire(owner: self, route: { event, tag in
            guard tag == marker else { return }
            receiver.isEditable = true
            if event.type == .keyDown { receiver.keyDown(with: event) }
            if event.type == .keyUp { receiver.keyUp(with: event) }
            receiver.isEditable = false
            if !triggered && event.type == .keyUp && event.keyCode == 14 && event.modifierFlags.contains(.option) {
                triggered = true
                if control == "pause" { session.pause() }
                if control == "cancel" { session.cancel() }
            }
        }, userInput: { _ in false }) else { throw Failure.message("Composition receiver is busy.") }
        defer { session.cancel(); PlaybackCheckRouter.shared.release(owner: self) }
        DispatchQueue.global(qos: .userInitiated).async {
            let result = session.run(plan: plan)
            DispatchQueue.main.async { outcome = result; finished = true }
        }
        let deadline = Date().addingTimeInterval(5)
        while !triggered && Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        guard triggered else { throw Failure.message("No accent prefix arrived for \(control).") }
        if control == "pause" {
            try await Task.sleep(for: .milliseconds(180))
            guard receiver.string.isEmpty && !receiver.hasMarkedText() else {
                throw Failure.message("Pause left composition pending: \(receiver.string.debugDescription)")
            }
            session.resume()
        }
        while !finished && Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        try await Task.sleep(for: .milliseconds(300))
        let expected = control == "pause" ? "éa" : ""
        guard finished, receiver.string == expected, !receiver.hasMarkedText(),
              outcome == (control == "pause" ? .complete : control == "cancel" ? .cancelled : .failed) else {
            throw Failure.message("Accent \(control): received \(receiver.string.debugDescription), marked \(receiver.hasMarkedText()), finished \(finished).")
        }
    }

    private func verifySavedContinuation(_ control: String) async throws {
        guard let receiver = controller.receiver else { throw Failure.message("No saved-run receiver.") }
        receiver.string = ""; receiver.setSelectedRange(NSRange(location: 0, length: 0))
        receiver.setAccessibilityIdentifier("typer.saved-run.receiver")
        let source = CGEventSource(stateID: .privateState)
        let marker = PlaybackCheckRouter.signature | (Int64(UInt32.random(in: 1...UInt32.max)) << 16)
        let events: [PlannedEvent]
        let expected: String
        if control == "selection" {
            expected = "good"
            events = "bad".map { PlannedEvent(kind: .character, value: String($0), flight: 100, dwell: 100) }
                + (0..<3).map { _ in PlannedEvent(kind: .shiftArrowLeft, flight: 100, dwell: 100) }
                + "good".map { PlannedEvent(kind: .character, value: String($0), flight: 100, dwell: 100) }
        } else {
            expected = "éa"
            events = expected.map { PlannedEvent(kind: .character, value: String($0), flight: 100, dwell: 100) }
        }
        let normalized = KeyTimeline.normalized(events)
        let plan = TypingPlan(events: normalized.events, duration: normalized.duration, repairs: 1, effectiveWPM: 0)
        func transport(_ action: PhysicalKeyAction) -> Bool {
            guard let event = KeyboardEventPoster.make(action, source: source, marker: marker) else { return false }
            KeyboardEventPoster.post(event, to: ProcessInfo.processInfo.processIdentifier); return true
        }
        let original = PlaybackSession(emit: transport)
        var triggered = false, finished = false, result: PlaybackSession.Outcome?
        guard PlaybackCheckRouter.shared.acquire(owner: self, route: { event, tag in
            guard tag == marker else { return }
            receiver.isEditable = true
            if event.type == .keyDown { receiver.keyDown(with: event) }
            if event.type == .keyUp { receiver.keyUp(with: event) }
            receiver.isEditable = false
            let boundary = control == "selection"
                ? event.type == .keyDown && event.keyCode == 123 && event.modifierFlags.contains(.shift)
                : event.type == .keyUp && event.keyCode == 14 && event.modifierFlags.contains(.option)
            if !triggered && boundary { triggered = true; original.pause() }
        }, userInput: { _ in false }) else { throw Failure.message("Saved-run receiver is busy.") }
        defer { original.cancel(); PlaybackCheckRouter.shared.release(owner: self) }
        DispatchQueue.global(qos: .userInitiated).async {
            let outcome = original.run(plan: plan)
            DispatchQueue.main.async { result = outcome; finished = true }
        }
        let deadline = Date().addingTimeInterval(15)
        while !triggered && Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        guard triggered else { throw Failure.message("No saved-run boundary for \(control).") }
        try await Task.sleep(for: .milliseconds(200))
        guard let checkpoint = original.checkpoint() else { throw Failure.message("No saved checkpoint.") }
        var fieldState: SavedFieldState?
        let axField = Self.findSavedReceiver()
        if control == "selection" {
            guard let axField else { throw Failure.message("No Accessibility field for the saved selection.") }
            fieldState = KeyboardEventPoster.captureFieldState(axField)
            guard fieldState?.selection == NSRange(location: 2, length: 1) else {
                throw Failure.message("Could not capture the saved selection: \(String(describing: fieldState)).")
            }
        }
        let run = SavedTypingRun(context: TypingRunContext(text: expected, settings: TypingSettings()), plan: plan,
            checkpoint: checkpoint, layoutIdentifier: KeyboardLayout.us.identifier,
            actions: KeyTimeline.physicalActions(for: plan.events), targetBundleIdentifier: "com.tapir132.typer",
            targetName: "Native receiver", field: fieldState)
        let store = SavedRunStore(url: output.appendingPathComponent("saved-run-\(control).json"))
        try store.save(run)
        let reloaded = try SavedRunStore(url: store.url).load()
        guard let reloaded, reloaded.isCompatible(with: .us) else { throw Failure.message("Saved run did not round trip.") }
        original.cancel()
        while !finished && Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        guard result == .cancelled else { throw Failure.message("Original saved run did not cancel.") }
        if let savedField = reloaded.resumeField, let axField {
            // Simulate returning later with the caret moved in the unchanged document.
            let originalText = receiver.string
            receiver.string += " changed"
            receiver.setSelectedRange(NSRange(location: 0, length: 0))
            guard !KeyboardEventPoster.restoreFieldState(savedField, in: axField) else {
                throw Failure.message("A changed document incorrectly passed saved-run verification.")
            }
            receiver.string = originalText
            receiver.setSelectedRange(NSRange(location: 0, length: 0))
            receiver.isEditable = true
            let restored = KeyboardEventPoster.restoreFieldState(savedField, in: axField)
            receiver.isEditable = false
            guard restored else { throw Failure.message("Could not restore the saved cursor range.") }
        }
        try store.remove()
        guard !store.hasStoredRun else { throw Failure.message("The old checkpoint was not consumed.") }
        let resumed = PlaybackSession(emit: transport)
        defer { resumed.cancel() }
        finished = false
        DispatchQueue.global(qos: .userInitiated).async {
            let outcome = resumed.run(plan: reloaded.plan, checkpoint: reloaded.resumeCheckpoint)
            DispatchQueue.main.async { result = outcome; finished = true }
        }
        while !finished && Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        try await Task.sleep(for: .milliseconds(250))
        guard finished, result == .complete, receiver.string == expected, !receiver.hasMarkedText() else {
            throw Failure.message("Saved \(control) resumed as \(receiver.string.debugDescription), expected \(expected.debugDescription).")
        }
        try store.remove()
    }

    private static func findSavedReceiver() -> AXUIElement? {
        let app = AXUIElementCreateApplication(ProcessInfo.processInfo.processIdentifier)
        AXUIElementSetMessagingTimeout(app, 0.2)
        func find(_ element: AXUIElement, depth: Int) -> AXUIElement? {
            guard depth < 18 else { return nil }
            var identifier: CFTypeRef?
            if AXUIElementCopyAttributeValue(element, kAXIdentifierAttribute as CFString, &identifier) == .success,
               identifier as? String == "typer.saved-run.receiver" { return element }
            for name in [kAXWindowsAttribute, kAXChildrenAttribute] {
                var value: CFTypeRef?
                if AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success,
                   let children = value as? [AXUIElement] {
                    for child in children.prefix(100) { if let result = find(child, depth: depth + 1) { return result } }
                }
            }
            return nil
        }
        return find(app, depth: 0)
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        lifecycle.applicationShouldTerminate(sender)
    }

    private func prepareQuitCheckpointCheck() async throws {
        let normalized = KeyTimeline.normalized([
            PlannedEvent(kind: .character, value: "a", flight: 10, dwell: 20),
            PlannedEvent(kind: .character, value: "b", flight: 300_000, dwell: 20, pauseKind: .paragraph)
        ])
        let plan = TypingPlan(events: normalized.events, duration: normalized.duration, repairs: 0, effectiveWPM: 0)
        let checkpoint = PlaybackCheckpoint(nextAction: 2, elapsed: 0.03)
        let context = TypingRunContext(text: "ab", settings: TypingSettings())
        let store = SavedRunStore(url: output.appendingPathComponent("quit-saved-run.json"))
        try store.save(SavedTypingRun(context: context, plan: plan, checkpoint: checkpoint,
            layoutIdentifier: KeyboardLayout.us.identifier, actions: KeyTimeline.physicalActions(for: plan.events),
            targetBundleIdentifier: "com.tapir132.typer", targetName: "Quit verification"))
        let suite = "typer.quit-verification.\(UUID())"
        guard let defaults = UserDefaults(suiteName: suite) else { throw Failure.message("No isolated shortcut preferences.") }
        let manager = ShortcutManager(defaults: defaults, driver: QuitCheckShortcuts())
        let typing = TypingController(shortcuts: manager, savedRuns: store)
        typing.overlayEnabled = false
        try store.remove() // consume the old checkpoint, as real Resume does
        typing.run(plan: plan, session: PlaybackSession { _ in true }, target: .current, field: nil, context: context, checkpoint: checkpoint)
        savedOnQuit = typing
        quitObserver = NotificationCenter.default.addObserver(forName: .typerWillQuit, object: nil, queue: .main) { [weak typing] note in
            MainActor.assumeIsolated {
                if let request = note.object as? TyperQuitRequest {
                    request.prepare.append { await typing?.prepareForQuit() ?? false }
                }
            }
        }
        try await Task.sleep(for: .milliseconds(100))
        defaults.removePersistentDomain(forName: suite)
        typing.requestSaveForLater() // the following Quit must await this write
    }

    enum Failure: Error { case message(String) }
}

@MainActor
private final class QuitCheckShortcuts: ShortcutRegistering {
    var onPress: ((UInt32) -> Void)?
    func register(_ binding: ShortcutBinding, id: UInt32) -> Bool { true }
    func unregister(_ id: UInt32) {}
}

@main
struct PlaybackVerificationApp {
    @MainActor static func main() {
        let output = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        let app = NSApplication.shared
        let delegate = PlaybackVerificationDelegate(output: output)
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }
}
