import SwiftUI

@main
struct TyperApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            RootView(model: model)
                .frame(minWidth: 920, minHeight: 660)
                .preferredColorScheme(.dark)
        }
        .defaultSize(width: 1240, height: 800)
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandMenu("Typing") {
                Button("Arm Typing") { model.arm() }
                    .keyboardShortcut(.return, modifiers: .command)
                Button("Stop Typing") { model.controller.stop() }
                    .keyboardShortcut(.escape, modifiers: .command)
            }
        }
    }
}
