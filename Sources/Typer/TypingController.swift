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

    init() {
        GlobalStopHotKey.shared.onTrigger = { [weak self] in self?.stop() }
        GlobalStopHotKey.shared.onTogglePause = { [weak self] in self?.togglePause() }
        GlobalStopHotKey.shared.onSkipWait = { [weak self] in self?.skipWait() }
        GlobalStopHotKey.shared.register()
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
        GlobalStopHotKey.shared.disablePlaybackControls()
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
                             message: pauseMessage, enabled: overlayEnabled)
    }

    private func begin(_ plan: TypingPlan) {
        guard let target = NSWorkspace.shared.frontmostApplication, target.processIdentifier != ProcessInfo.processInfo.processIdentifier else {
            state = .error("Focus the target application before typing starts.")
            return
        }
        guard GlobalStopHotKey.shared.enablePlaybackControls() else {
            state = .error("The pause or skip shortcut is already in use. Free ⌘⌥P and ⌘⌥→ in the other app, then try again.")
            return
        }
        self.target = target
        state = .typing
        progress = PlaybackProgress(remaining: plan.duration / 1_000)
        let source = CGEventSource(stateID: .privateState)
        let session = PlaybackSession { action in
            guard let event = KeyboardEventPoster.make(action, source: source) else { return false }
            event.post(tap: .cghidEventTap)
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
                GlobalStopHotKey.shared.disablePlaybackControls()
                self.screenOverlay.hide()
                self.target = nil
                switch outcome {
                case .complete: self.state = .complete
                case .cancelled: self.state = .stopped
                case .failed: self.state = .error("A keyboard event could not be created. Playback stopped and held keys were released.")
                }
            }
        }
    }

}

/// The diagnostic receiver and cross-app playback share the same event creation.
/// Only the destination differs: the diagnostic posts to Typer's process alone.
enum KeyboardEventPoster {
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

/// Carbon hot keys are handled by the window server, work before Accessibility
/// is granted, and consume Escape so it does not leak into the target editor.
@MainActor
final class GlobalStopHotKey {
    static let shared = GlobalStopHotKey()

    var onTrigger: (() -> Void)?
    var onTogglePause: (() -> Void)?
    var onSkipWait: (() -> Void)?
    private(set) var isRegistered = false
    private var hotKeyRefs: [EventHotKeyRef] = []
    private var handlerRef: EventHandlerRef?
    private var playbackRefs: [EventHotKeyRef] = []

    func enablePlaybackControls() -> Bool {
        guard playbackRefs.isEmpty else { return true }
        for (code, id) in [(UInt32(kVK_ANSI_P), UInt32(3)), (UInt32(kVK_RightArrow), UInt32(4))] {
            var reference: EventHotKeyRef?
            let result = RegisterEventHotKey(code, UInt32(cmdKey | optionKey),
                EventHotKeyID(signature: 0x5459_5052, id: id), GetEventDispatcherTarget(), 0, &reference)
            guard result == noErr, let reference else { disablePlaybackControls(); return false }
            playbackRefs.append(reference)
        }
        return true
    }

    func disablePlaybackControls() {
        for reference in playbackRefs { UnregisterEventHotKey(reference) }
        playbackRefs = []
    }

    func register() {
        guard hotKeyRefs.isEmpty else { return }
        installHandler()
        let target = GetEventDispatcherTarget()
        let bindings: [(modifiers: UInt32, id: UInt32)] = [
            (UInt32(cmdKey), 1),
            (UInt32(controlKey), 2)
        ]
        for binding in bindings {
            var reference: EventHotKeyRef?
            let identifier = EventHotKeyID(signature: 0x5459_5052, id: binding.id) // "TYPR"
            let status = RegisterEventHotKey(
                UInt32(kVK_Escape),
                binding.modifiers,
                identifier,
                target,
                0,
                &reference
            )
            if status == noErr, let reference { hotKeyRefs.append(reference) }
            else { NSLog("Typer could not register emergency stop hot key (OSStatus %d)", status) }
        }
        isRegistered = hotKeyRefs.count == bindings.count
    }

    private func installHandler() {
        guard handlerRef == nil else { return }
        var spec = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        InstallEventHandler(GetEventDispatcherTarget(), { _, event, _ in
            var identifier = EventHotKeyID()
            guard GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                    nil, MemoryLayout<EventHotKeyID>.size, nil, &identifier) == noErr else { return noErr }
            MainActor.assumeIsolated {
                switch identifier.id {
                case 3: GlobalStopHotKey.shared.onTogglePause?()
                case 4: GlobalStopHotKey.shared.onSkipWait?()
                default: GlobalStopHotKey.shared.onTrigger?()
                }
            }
            return noErr
        }, 1, &spec, nil, &handlerRef)
    }
}

enum KeyboardMap {
    private static let base: [Character: CGKeyCode] = [
        "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9,
        "b": 11, "q": 12, "w": 13, "e": 14, "r": 15, "y": 16, "t": 17, "1": 18, "2": 19,
        "3": 20, "4": 21, "6": 22, "5": 23, "=": 24, "9": 25, "7": 26, "-": 27, "8": 28,
        "0": 29, "]": 30, "o": 31, "u": 32, "[": 33, "i": 34, "p": 35, "l": 37, "j": 38,
        "'": 39, "k": 40, ";": 41, "\\": 42, ",": 43, "/": 44, "n": 45, "m": 46, ".": 47,
        "`": 50, " ": 49
    ]
    private static let shifted: [Character: Character] = [
        "!": "1", "@": "2", "#": "3", "$": "4", "%": "5", "^": "6", "&": "7", "*": "8",
        "(": "9", ")": "0", "_": "-", "+": "=", "{": "[", "}": "]", "|": "\\", ":": ";",
        "\"": "'", "<": ",", ">": ".", "?": "/", "~": "`"
    ]

    static func lookup(_ string: String) -> (code: CGKeyCode, shift: Bool)? {
        guard string.count == 1, let character = string.first else { return nil }
        guard string.lowercased().count == 1, let lower = string.lowercased().first else { return nil }
        if let code = base[lower] { return (code, character.isUppercase) }
        if let plain = shifted[character], let code = base[plain] { return (code, true) }
        return nil
    }
}
