import SwiftUI

extension Notification.Name {
    /// Posted before termination so views can dismiss their sheets.
    static let typerWillQuit = Notification.Name("typerWillQuit")
}

/// SwiftUI cancels app termination while any sheet is presented, without
/// consulting the app delegate. That blocks Cmd+Q and Sparkle's
/// install-and-relaunch, which quits the app through a Quit Apple Event.
/// Both paths are routed here: dismiss sheets first, then terminate.
final class TyperAppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSAppleEventManager.shared().setEventHandler(
            self,
            andSelector: #selector(handleQuitEvent(_:withReply:)),
            forEventClass: AEEventClass(kCoreEventClass),
            andEventID: AEEventID(kAEQuitApplication)
        )
    }

    @objc private func handleQuitEvent(_ event: NSAppleEventDescriptor, withReply reply: NSAppleEventDescriptor) {
        Self.quit()
    }

    static func quit(attempt: Int = 0) {
        NotificationCenter.default.post(name: .typerWillQuit, object: nil)
        // ponytail: poll for the sheet window to go away (up to ~1s), then give up and try anyway.
        if attempt < 20, NSApp.windows.contains(where: \.isSheet) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { quit(attempt: attempt + 1) }
        } else {
            NSApp.terminate(nil)
        }
    }
}

@main
struct TyperApp: App {
    @NSApplicationDelegateAdaptor(TyperAppDelegate.self) private var appDelegate
    @StateObject private var model = AppModel()
    private let updateManager = UpdateManager.shared

    var body: some Scene {
        WindowGroup {
            RootView(model: model)
                .frame(minWidth: 920, minHeight: 660)
                .preferredColorScheme(.dark)
        }
        .defaultSize(width: 1240, height: 800)
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandGroup(replacing: .appTermination) {
                Button("Quit Typer") { TyperAppDelegate.quit() }.keyboardShortcut("q", modifiers: .command)
            }
            CommandGroup(after: .appInfo) {
                Button("Check for Updates…") { updateManager.checkForUpdates() }
                    .disabled(!updateManager.canCheckForUpdates)
            }
            CommandMenu("Typing") {
                Button("Arm Typing") { model.arm() }
                    .keyboardShortcut(.return, modifiers: .command)
                Button("Stop Typing") { model.controller.stop() }
                    .keyboardShortcut(.escape, modifiers: .command)
            }
            CommandGroup(replacing: .help) {
                Button("Typer Guide") { model.showGuide(.firstRun) }
                    .keyboardShortcut("?", modifiers: .command)
            }
        }
    }
}
