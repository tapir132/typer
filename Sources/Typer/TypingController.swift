import AppKit
import ApplicationServices
import Carbon.HIToolbox
import Foundation

@MainActor
final class TypingController: ObservableObject {
    @Published private(set) var state: RunState = .ready
    @Published private(set) var lastPlan: TypingPlan?
    @Published private(set) var progress = PlaybackProgress()
    @Published private(set) var pauseMessage: String?
    @Published var overlayEnabled = true { didSet { refreshOverlay() } }
    private let screenOverlay = TypingScreenOverlay()
    private var target: NSRunningApplication?
    private var focusObserver: NSObjectProtocol?

    private var countdownTask: Task<Void, Never>?
    private var planningTask: Task<Void, Never>?
    private var playbackSession: PlaybackSession?
    private let playbackQueue = DispatchQueue(label: "typer.playback", qos: .userInitiated)

    let shortcuts: ShortcutManager
    var onArm: (() -> Void)?

    init(shortcuts: ShortcutManager? = nil) {
        let shortcuts = shortcuts ?? ShortcutManager()
        self.shortcuts = shortcuts
        shortcuts.onAction = { [weak self] action in
            guard let self else { return }
            switch action {
            case .arm: self.onArm?()
            case .pause: self.togglePause()
            case .skipWait: self.skipWait()
            case .stop: self.stop()
            }
        }
        shortcuts.onBindingsChanged = { [weak self] in self?.refreshOverlay() }
        shortcuts.start()
        focusObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification,
            object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, self.state == .typing,
                          NSWorkspace.shared.frontmostApplication?.processIdentifier != self.target?.processIdentifier else { return }
                    self.pause(message: "App changed. Return to the same field in \(self.target?.localizedName ?? "the target app") to resume.")
                }
            }
    }

    deinit {
        if let focusObserver { NSWorkspace.shared.notificationCenter.removeObserver(focusObserver) }
        playbackSession?.cancel()
    }

    var accessibilityGranted: Bool { AXIsProcessTrusted() }

    @discardableResult
    func requestAccessibility() -> Bool {
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    func openAccessibilitySettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") else { return }
        NSWorkspace.shared.open(url)
    }

    func start(text: String, settings: TypingSettings, profile: TypingProfile) {
        guard !text.isEmpty else { return }
        guard accessibilityGranted else {
            _ = requestAccessibility()
            state = .error("Enable Typer in System Settings → Privacy & Security → Accessibility.")
            return
        }
        stop(resetState: false)
        state = .preparing
        planningTask = Task { [weak self] in
            let plan = await Task.detached(priority: .userInitiated) {
                TypingEngine.generatePlan(text: text, settings: settings, profile: profile)
            }.value
            guard !Task.isCancelled, let self else { return }
            self.planningTask = nil
            self.startCountdown(with: plan)
        }
    }

    func start(plan: TypingPlan) {
        guard !plan.events.isEmpty else { return }
        guard accessibilityGranted else {
            _ = requestAccessibility()
            state = .error("Enable Typer in System Settings → Privacy & Security → Accessibility.")
            return
        }
        stop(resetState: false)
        startCountdown(with: plan)
    }

    private func startCountdown(with plan: TypingPlan) {
        if let error = shortcuts.preparePlayback() { state = .error(error); return }
        lastPlan = plan
        state = .armed(5)
        countdownTask = Task { [weak self] in
            for count in stride(from: 4, through: 0, by: -1) {
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled else { return }
                guard let self else { return }
                if count > 0 { self.state = .armed(count) }
            }
            guard !Task.isCancelled, let self else { return }
            guard !NSApp.isActive else {
                self.shortcuts.finishPlayback()
                self.state = .error("Click into another application before the countdown ends.")
                return
            }
            self.begin(plan)
        }
    }

    func stop(resetState: Bool = true) {
        planningTask?.cancel()
        planningTask = nil
        countdownTask?.cancel()
        countdownTask = nil
        playbackSession?.cancel()
        playbackSession = nil
        shortcuts.finishPlayback()
        screenOverlay.hide()
        target = nil
        pauseMessage = nil
        progress = PlaybackProgress()
        if resetState { state = .stopped }
    }

    func reset() { if !state.isBusy { state = .ready } }

    func togglePause() {
        if state == .typing { pause() }
        else if state == .paused {
            guard let target, !target.isTerminated,
                  NSWorkspace.shared.frontmostApplication?.processIdentifier == target.processIdentifier else {
                pauseMessage = "Focus the same field in \(target?.localizedName ?? "the target app") before resuming."
                refreshOverlay()
                return
            }
            playbackSession?.resume()
            pauseMessage = nil
            progress.isPaused = false
            state = .typing
            refreshOverlay()
        }
    }

    func pause(message: String? = nil) {
        guard state == .typing else { return }
        playbackSession?.pause()
        state = .paused
        pauseMessage = message
        progress.isPaused = true
        refreshOverlay()
    }

    func skipWait() {
        guard state == .typing else { return }
        _ = playbackSession?.skipWait()
    }

    func focusTarget() { target?.activate(options: []) }

    private func refreshOverlay() {
        screenOverlay.update(state: state, progress: progress, target: target?.localizedName ?? "the target app",
                             message: pauseMessage, enabled: overlayEnabled, shortcuts: shortcuts.bindings, stopText: shortcuts.stopDescription)
    }

    private func begin(_ plan: TypingPlan) {
        guard let target = NSWorkspace.shared.frontmostApplication, target.processIdentifier != ProcessInfo.processInfo.processIdentifier else {
            shortcuts.finishPlayback()
            state = .error("Focus the target application before typing starts.")
            return
        }
        guard let layout = KeyboardLayout.current() else {
            shortcuts.finishPlayback()
            state = .error("Choose a keyboard layout such as U.S., British or French before typing. This input method does not expose a direct key layout.")
            return
        }
        let layoutGuard = PlaybackLayoutGuard(identifier: layout.identifier)
        let originalField = KeyboardEventPoster.focusedElement(in: target.processIdentifier)
        self.target = target
        state = .typing
        progress = PlaybackProgress(remaining: plan.duration / 1_000)
        let source = CGEventSource(stateID: .privateState)
        let session = PlaybackSession(layout: layout) { action in
            if action.isDown && !layoutGuard.isCurrent { return false }
            if action.isCompositionCleanup && !KeyboardEventPoster.canCleanUpComposition(in: target.processIdentifier, field: originalField) { return false }
            guard let event = KeyboardEventPoster.make(action, source: source) else { return false }
            // Bind this run, including cleanup releases, to its chosen app.
            // The global HID route can have modifier combinations intercepted
            // before they reach the target (observed in Safari symbol checks).
            KeyboardEventPoster.post(event, to: target.processIdentifier)
            return true
        }
        playbackSession = session
        refreshOverlay()
        playbackQueue.async { [weak self] in
            let outcome = session.run(plan: plan, onProgress: { progress in
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.playbackSession === session else { return }
                    var progress = progress
                    progress.isPaused = self.state == .paused
                    self.progress = progress
                    self.refreshOverlay()
                }
            })
            DispatchQueue.main.async { [weak self] in
                guard let self, self.playbackSession === session else { return }
                self.playbackSession = nil
                self.shortcuts.finishPlayback()
                self.screenOverlay.hide()
                self.target = nil
                switch outcome {
                case .complete: self.state = .complete
                case .cancelled: self.state = .stopped
                case .failed: self.state = .error("Typing stopped because the keyboard layout changed or a key could not be sent. Check the field for an unfinished accent before starting again.")
                }
            }
        }
    }

}

/// The diagnostic receiver and cross-app playback share the same event creation.
/// Only the destination differs: the diagnostic posts to Typer's process alone.
enum KeyboardEventPoster {
    static func focusedElement(in processID: pid_t) -> AXUIElement? {
        let app = AXUIElementCreateApplication(processID)
        AXUIElementSetMessagingTimeout(app, 0.2)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXFocusedUIElementAttribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return unsafeBitCast(value, to: AXUIElement.self)
    }

    static func canCleanUpComposition(in processID: pid_t, field: AXUIElement?) -> Bool {
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == processID,
              let field, let current = focusedElement(in: processID) else { return false }
        return CFEqual(field, current)
    }

    static func post(_ event: CGEvent, to processID: pid_t) {
        event.postToPid(processID)
    }

    static func make(_ action: PhysicalKeyAction, source: CGEventSource?, marker: Int64 = 0) -> CGEvent? {
        guard let event = CGEvent(keyboardEventSource: source, virtualKey: action.code, keyDown: action.isDown) else { return nil }
        event.flags = []
        if action.shift { event.flags.insert(.maskShift) }
        if action.option { event.flags.insert(.maskAlternate) }
        if !action.unicode.isEmpty {
            let units = Array(action.unicode.utf16)
            units.withUnsafeBufferPointer {
                event.keyboardSetUnicodeString(stringLength: $0.count, unicodeString: $0.baseAddress)
            }
        }
        event.setIntegerValueField(.eventSourceUserData, value: marker)
        return event
    }
}
