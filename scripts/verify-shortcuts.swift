import AppKit
import SwiftUI

/// A background receiver for the production recorder and Carbon registration.
/// Uses isolated preferences and only posts chords after successful registration.
@MainActor
final class ShortcutVerificationDelegate: NSObject, NSApplicationDelegate {
    let output: URL
    let suite = "typer.shortcut-verification.\(UUID())"
    var shortcuts: ShortcutManager!
    var window: NSWindow!
    var actions: [ShortcutAction] = []
    var deliveredIDs: [UInt32] = []
    init(output: URL) { self.output = output }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let defaults = UserDefaults(suiteName: suite)!
        let driver = SystemShortcutDriver()
        shortcuts = ShortcutManager(defaults: defaults, driver: driver)
        let route = driver.onPress
        driver.onPress = { [weak self] id in self?.deliveredIDs.append(id); route?(id) }
        shortcuts.onAction = { [weak self] action in self?.actions.append(action) }
        shortcuts.start()
        window = NSWindow(contentRect: NSRect(x: -10_000, y: -10_000, width: 800, height: 720),
                          styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: ShortcutSettingsView(shortcuts: shortcuts).preferredColorScheme(.dark))
        window.orderBack(nil)
        Task { @MainActor in
            do {
                try await Task.sleep(for: .milliseconds(200))
                for (action, code, label) in [(ShortcutAction.stop, UInt16(64), "F17"), (.pause, 79, "F18"), (.skipWait, 80, "F19")] {
                    guard shortcuts.beginRecording(action), shortcuts.setBinding(binding(code, label), for: action) == nil else {
                        throw Failure.message("Could not register isolated \(label) fixture: \(shortcuts.errors)")
                    }
                    shortcuts.endRecording(action)
                }
                guard shortcuts.preparePlayback() == nil else { throw Failure.message("Playback shortcut registration failed.") }
                // Typer is not active here. Carbon must deliver from outside its window.
                guard !NSApp.isActive else { throw Failure.message("The verification app unexpectedly has focus.") }
                try await press(.pause)
                try await press(.skipWait)
                try await press(.stop)
                guard actions == [.pause, .skipWait, .stop] else { throw Failure.message("Unexpected delivered actions: \(actions)") }
                shortcuts.finishPlayback()
                try await Task.sleep(for: .milliseconds(150))

                // Drive the actual view to rebind pause a second time.
                guard let recorder = recorder(in: window.contentView!, action: .pause) else { throw Failure.message("Recorder not mounted.") }
                recorder.beginRecording()
                let flags: NSEvent.ModifierFlags = [.control, .option, .command, .capsLock]
                NSApp.sendEvent(key(.keyDown, code: 2, flags: flags, characters: "D"))
                NSApp.sendEvent(key(.keyUp, code: 2, flags: [], characters: "D"))
                guard shortcuts.bindings.pause.keyCode == 2, !recorder.isRecording else { throw Failure.message("Visible recorder did not save Command–Control–Option–D: \(shortcuts.errors)") }
                guard ShortcutManager(defaults: defaults).bindings.pause.keyCode == 2 else { throw Failure.message("Shortcut did not survive reload.") }
                guard shortcuts.preparePlayback() == nil else { throw Failure.message("Rebound shortcut unavailable.") }
                try await press(.pause)
                guard actions == [.pause, .skipWait, .stop, .pause] else { throw Failure.message("Rebound shortcut did not fire exactly once.") }
                shortcuts.finishPlayback()
                let result: [String: Any] = ["passed": true, "actions": actions.map(\.title),
                    "reboundPause": shortcuts.bindings.pause.displayText, "applicationWasInactive": !NSApp.isActive]
                try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]).write(to: output.appendingPathComponent("result.json"))
            } catch {
                try? JSONSerialization.data(withJSONObject: ["passed": false, "error": String(describing: error)], options: [.prettyPrinted]).write(to: output.appendingPathComponent("result.json"))
            }
            defaults.removePersistentDomain(forName: suite)
            shortcuts.finishPlayback()
            window.close(); NSApp.terminate(nil)
        }
    }

    private func binding(_ code: UInt16, _ label: String) -> ShortcutBinding {
        ShortcutBinding(keyCode: code, modifiersRawValue: NSEvent.ModifierFlags([.control, .option, .command]).rawValue, keyLabel: label)
    }

    private func press(_ action: ShortcutAction) async throws {
        // Let the host apply state changes and the window server settle the
        // registration before injecting a fresh key-down, as a user would.
        try await Task.sleep(for: .milliseconds(200))
        let binding = shortcuts.bindings[action]
        guard shortcuts.errors[action] == nil, let code = binding.keyCode else { throw Failure.message("Refusing unregistered key event.") }
        let before = actions.count
        let source = CGEventSource(stateID: .privateState)
        for down in [true, false] {
            guard let event = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: down) else { throw Failure.message("No keyboard event.") }
            event.flags = [.maskCommand, .maskControl, .maskAlternate]
            if ShortcutBinding.functionKeyLabels[code] != nil { event.flags.insert(.maskSecondaryFn) }
            event.post(tap: .cghidEventTap)
            try await Task.sleep(for: .milliseconds(50))
        }
        for _ in 0..<50 {
            if actions.count > before { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        throw Failure.message("No global delivery for \(binding.displayText). AX trusted: \(AXIsProcessTrusted()); posting allowed: \(CGPreflightPostEventAccess()); driver IDs: \(deliveredIDs); recording: \(String(describing: shortcuts.recordingAction)).")
    }

    private func key(_ type: NSEvent.EventType, code: UInt16, flags: NSEvent.ModifierFlags, characters: String) -> NSEvent {
        NSEvent.keyEvent(with: type, location: .zero, modifierFlags: flags, timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber, context: nil, characters: characters,
            charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code)!
    }

    private func recorder(in view: NSView, action: ShortcutAction) -> ShortcutRecorderNSView? {
        if let recorder = view as? ShortcutRecorderNSView, recorder.action == action { return recorder }
        return view.subviews.lazy.compactMap { self.recorder(in: $0, action: action) }.first
    }

    enum Failure: Error { case message(String) }
}

@main
struct ShortcutVerificationApp {
    @MainActor static func main() {
        let app = NSApplication.shared
        let delegate = ShortcutVerificationDelegate(output: URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true))
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }
}
