import AppKit
import SwiftUI

/// Run in a real application event loop, independently of the user's Typer app
/// and its profiles. Every generated event is addressed only to this process.
@MainActor
final class PlaybackVerificationDelegate: NSObject, NSApplicationDelegate {
    var window: NSWindow!
    var controller = PlaybackCheckController(requiresFocus: false)
    let output: URL
    init(output: URL) { self.output = output }

    func applicationDidFinishLaunching(_ notification: Notification) {
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
                try JSONSerialization.data(withJSONObject: ["passed": true, "scenarios": 3, "compositionControls": ["pause", "cancel", "failure"]], options: [.prettyPrinted]).write(to: output.appendingPathComponent("result.json"))
            } catch {
                try? JSONSerialization.data(withJSONObject: ["passed": false, "error": String(describing: error)], options: [.prettyPrinted]).write(to: output.appendingPathComponent("result.json"))
            }
            controller.close()
            window.close()
            NSApp.terminate(nil)
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

    enum Failure: Error { case message(String) }
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
