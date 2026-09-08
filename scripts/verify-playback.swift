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
                try JSONSerialization.data(withJSONObject: ["passed": true, "scenarios": 3], options: [.prettyPrinted]).write(to: output.appendingPathComponent("result.json"))
            } catch {
                try? JSONSerialization.data(withJSONObject: ["passed": false, "error": String(describing: error)], options: [.prettyPrinted]).write(to: output.appendingPathComponent("result.json"))
            }
            controller.close()
            window.close()
            NSApp.terminate(nil)
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
