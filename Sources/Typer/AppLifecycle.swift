import AppKit
import Foundation

extension Notification.Name {
    /// Posted before termination so views can dismiss their sheets.
    static let typerWillQuit = Notification.Name("typerWillQuit")
}

@MainActor
final class TyperQuitRequest {
    var prepare: [() async -> Bool] = []
    var error: String?
}

/// SwiftUI cancels app termination while any sheet is presented, without
/// consulting the app delegate. That blocks Cmd+Q and Sparkle's
/// install-and-relaunch, which quits the app through a Quit Apple Event.
/// Both paths are routed here: dismiss sheets first, then terminate.
final class TyperAppDelegate: NSObject, NSApplicationDelegate {
    private static var quitTask: Task<Void, Never>?
    private static var preparedForTermination = false
    private static var pendingTerminateReply = false
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSAppleEventManager.shared().setEventHandler(
            self,
            andSelector: #selector(handleQuitEvent(_:withReply:)),
            forEventClass: AEEventClass(kCoreEventClass),
            andEventID: AEEventID(kAEQuitApplication)
        )
    }

    @objc @MainActor private func handleQuitEvent(_ event: NSAppleEventDescriptor, withReply reply: NSAppleEventDescriptor) {
        Self.quit()
    }

    @MainActor func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if Self.preparedForTermination { return .terminateNow }
        Self.pendingTerminateReply = true
        Self.quit()
        return .terminateLater
    }

    @MainActor static func quit() {
        guard quitTask == nil else { return }
        let request = TyperQuitRequest()
        NotificationCenter.default.post(name: .typerWillQuit, object: request)
        quitTask = Task { @MainActor in
            for prepare in request.prepare {
                guard await prepare() else {
                    // A real disk error leaves the run paused and visible so
                    // the user can retry; never silently lose a saved job.
                    NSApp.activate(ignoringOtherApps: true)
                    if pendingTerminateReply {
                        pendingTerminateReply = false
                        NSApp.reply(toApplicationShouldTerminate: false)
                    }
                    let alert = NSAlert()
                    alert.messageText = "Couldn’t save this typing run"
                    alert.informativeText = (request.error ?? "The run is still paused in Typer.") + "\n\nKeep Typer open to retry, or quit and lose this unsaved position."
                    alert.addButton(withTitle: "Keep Typer open")
                    alert.addButton(withTitle: "Quit without saving")
                    if alert.runModal() == .alertSecondButtonReturn {
                        preparedForTermination = true
                        NSApp.terminate(nil)
                        preparedForTermination = false
                    }
                    quitTask = nil; return
                }
            }
            for _ in 0..<20 where NSApp.windows.contains(where: \.isSheet) {
                try? await Task.sleep(for: .milliseconds(50))
            }
            if pendingTerminateReply {
                pendingTerminateReply = false
                NSApp.reply(toApplicationShouldTerminate: true)
            } else {
                preparedForTermination = true
                NSApp.terminate(nil)
                preparedForTermination = false
            }
            quitTask = nil
        }
    }
}
