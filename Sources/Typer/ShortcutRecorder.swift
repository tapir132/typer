import AppKit
import SwiftUI

struct ShortcutRecorder: NSViewRepresentable {
    @ObservedObject var shortcuts: ShortcutManager
    let action: ShortcutAction

    func makeNSView(context: Context) -> ShortcutRecorderNSView {
        let view = ShortcutRecorderNSView()
        view.shortcuts = shortcuts; view.action = action
        view.updateTitle()
        return view
    }

    func updateNSView(_ view: ShortcutRecorderNSView, context: Context) {
        if view.isRecording && shortcuts.recordingAction != action { view.finishRecording() }
        view.shortcuts = shortcuts; view.action = action
        view.isEnabled = !shortcuts.playbackActive
        view.updateTitle()
    }

    static func dismantleNSView(_ view: ShortcutRecorderNSView, coordinator: ()) { view.finishRecording() }
}

/// Cadence's local-monitor approach captures menu equivalents before AppKit or
/// SwiftUI handles them. Wait for release before restoring global registrations,
/// so recording the current shortcut cannot accidentally run its action.
@MainActor
final class ShortcutRecorderNSView: NSView {
    weak var shortcuts: ShortcutManager?
    var action: ShortcutAction = .pause
    var isEnabled = true { didSet { button.isEnabled = isEnabled } }
    private let button = NSButton(title: "", target: nil, action: nil)
    private var monitor: Any?
    private var observers: [NSObjectProtocol] = []
    private var gesture = ModifierShortcutGesture()
    private var pending: ShortcutBinding?
    private var pendingKeyReleased = false
    private var modifiers: NSEvent.ModifierFlags = []
    var isRecording: Bool { monitor != nil }
    override var intrinsicContentSize: NSSize { NSSize(width: 190, height: 32) }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        button.bezelStyle = .recessed
        button.font = .monospacedSystemFont(ofSize: 11, weight: .semibold)
        button.target = self
        button.action = #selector(beginRecording)
        addSubview(button)
    }

    required init?(coder: NSCoder) { nil }
    override func layout() { button.frame = bounds }
    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow == nil { finishRecording() }
        super.viewWillMove(toWindow: newWindow)
    }

    @objc func beginRecording() {
        guard isEnabled, !isRecording, shortcuts?.beginRecording(action) == true else { return }
        button.title = "Press shortcut…"
        gesture.reset(); pending = nil; modifiers = []; pendingKeyReleased = false
        let mask: NSEvent.EventTypeMask = [.keyDown, .keyUp, .flagsChanged, .leftMouseDown, .rightMouseDown, .otherMouseDown]
        monitor = NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self] event in
            guard let self else { return event }
            return self.receive(event)
        }
        guard monitor != nil else { finishRecording(); return }
        let center = NotificationCenter.default
        for name in [NSApplication.didResignActiveNotification, NSWindow.willCloseNotification, NSWindow.didResignKeyNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] notification in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    if name == NSApplication.didResignActiveNotification || (notification.object as? NSWindow) === self.window {
                        self.finishRecording()
                    }
                }
            })
        }
    }

    func receive(_ event: NSEvent) -> NSEvent? {
        guard isRecording else { return event }
        if shortcuts?.recordingAction != action { finishRecording(); return event }
        switch event.type {
        case .keyDown:
            modifiers = event.modifierFlags.intersection(ShortcutBinding.shortcutModifiers)
            if event.keyCode == 53 && modifiers.isEmpty { finishRecording(); return nil }
            gesture.cancelChord()
            guard !event.isARepeat, pending == nil else { return nil }
            if let value = ShortcutBinding.from(event), value.isValid {
                pending = value; pendingKeyReleased = false
                button.title = "\(value.displayText) · release keys"
            } else { button.title = "Add ⌃⌥⌘ or F-key" }
            return nil
        case .keyUp:
            modifiers = event.modifierFlags.intersection(ShortcutBinding.shortcutModifiers)
            if pending?.keyCode == event.keyCode { pendingKeyReleased = true }
            finishPendingIfReleased()
            return nil
        case .flagsChanged:
            modifiers = event.modifierFlags.intersection(ShortcutBinding.shortcutModifiers)
            let chord = gesture.flagsChanged(modifiers)
            if pending != nil { finishPendingIfReleased() }
            else if let chord {
                if let value = ShortcutBinding.modifierOnly(chord) { accept(value) }
                else { button.title = "Add ⌃⌥⌘ or F-key" }
            }
            return nil
        default:
            finishRecording()
            return event
        }
    }

    private func finishPendingIfReleased() {
        guard let pending, pendingKeyReleased, modifiers.isEmpty else { return }
        self.pending = nil
        accept(pending)
    }

    private func accept(_ value: ShortcutBinding) {
        guard let shortcuts else { finishRecording(); return }
        if shortcuts.setBinding(value, for: action) != nil {
            button.title = "Choose another shortcut"
            pending = nil; gesture.reset()
        } else { finishRecording() }
    }

    func finishRecording() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        observers = []; pending = nil; gesture.reset()
        shortcuts?.endRecording(action)
        updateTitle()
    }

    func updateTitle() {
        button.setAccessibilityLabel("Change \(action.title.lowercased()) shortcut")
        button.setAccessibilityHelp("Click, then press a shortcut. Release the keys to save. Escape cancels.")
        guard !isRecording else { return }
        button.title = shortcuts?.bindings[action].displayText ?? "Record shortcut"
    }
}

struct ShortcutSettingsView: View {
    @ObservedObject var shortcuts: ShortcutManager
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("Keyboard shortcuts").font(.system(size: 20, weight: .semibold))
                Text("Click a shortcut, press the new keys, then release to save. Esc cancels.")
                    .font(.system(size: 12)).foregroundStyle(TyperTheme.mutedStrong)
                ForEach(ShortcutAction.allCases) { action in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 18) {
                            VStack(alignment: .leading, spacing: 5) {
                                Text(action.title).font(.system(size: 13, weight: .semibold))
                                Text(action.detail).font(.system(size: 11)).foregroundStyle(TyperTheme.mutedStrong)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            Spacer()
                            ShortcutRecorder(shortcuts: shortcuts, action: action).frame(width: 190, height: 32)
                        }
                        if let error = shortcuts.errors[action] {
                            Text(error).font(.system(size: 11)).foregroundStyle(TyperTheme.danger)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .padding(.vertical, 12)
                    .overlay(alignment: .bottom) { Rectangle().fill(TyperTheme.softLine).frame(height: 1) }
                }
                Text("Use a function key or a combination with ⌃, ⌥, or ⌘. Modifier-only shortcuts work when released without typing another key.")
                    .font(.system(size: 11)).foregroundStyle(TyperTheme.mutedStrong).fixedSize(horizontal: false, vertical: true)
                Text(shortcuts.backupAvailable ? "\(ShortcutBindings.backupStop.displayText) is also available as a backup Stop."
                     : "Backup Stop (\(ShortcutBindings.backupStop.displayText)) is unavailable. Your chosen Stop shortcut must be available before playback starts.")
                    .font(.system(size: 11)).foregroundStyle(TyperTheme.mutedStrong).fixedSize(horizontal: false, vertical: true)
                if shortcuts.playbackActive {
                    Text("Stop playback before changing shortcuts.").font(.system(size: 11)).foregroundStyle(TyperTheme.mutedStrong)
                }
                if let notice = shortcuts.loadNotice { Text(notice).font(.system(size: 11)).foregroundStyle(TyperTheme.danger) }
                Button("Restore default shortcuts") { shortcuts.restoreDefaults() }
                    .buttonStyle(SecondaryButtonStyle())
                    .disabled(shortcuts.playbackActive || shortcuts.recordingAction != nil)
            }
            .frame(maxWidth: 650, alignment: .leading).padding(26).frame(maxWidth: .infinity)
        }
    }
}
