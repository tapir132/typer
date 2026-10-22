import SwiftUI

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
            TypingCommands(model: model, controller: model.controller)
            CommandGroup(replacing: .appSettings) {
                Button("Settings…") { model.showSettings() }
                    .keyboardShortcut(",", modifiers: .command)
            }
            CommandGroup(replacing: .help) {
                Button("Typer Guide") { model.showGuide(.firstRun) }
                    .keyboardShortcut("?", modifiers: .command)
            }
        }
    }
}

private struct TypingCommands: Commands {
    @ObservedObject var model: AppModel
    @ObservedObject var controller: TypingController
    @ObservedObject private var shortcuts: ShortcutManager

    init(model: AppModel, controller: TypingController) {
        self.model = model; self.controller = controller; shortcuts = model.shortcuts
    }

    var body: some Commands {
        CommandMenu("Typing") {
            Button("Arm Typing (\(shortcuts.bindings.arm.displayText))") { model.arm() }
                .disabled(controller.state.isBusy || shortcuts.recordingAction != nil || shortcuts.previewActive)
            Button("Stop Typing (\(shortcuts.stopDescription))") { shortcuts.perform(.stop) }
            Button("Pause / Resume Typing (\(shortcuts.bindings.pause.displayText))") { shortcuts.perform(.pause) }
                .disabled(!controller.state.isPlaybackActive && !shortcuts.previewActive)
            Button("Skip Current Wait (\(shortcuts.bindings.skipWait.displayText))") { shortcuts.perform(.skipWait) }
                .disabled(!shortcuts.previewActive && (!controller.progress.canSkipWait || controller.state != .typing))
        }
    }
}
