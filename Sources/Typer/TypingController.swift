import AppKit
import ApplicationServices
import Foundation

@MainActor
final class TypingController: ObservableObject {
    @Published private(set) var state: RunState = .ready
    @Published private(set) var lastPlan: TypingPlan?

    private var countdownTask: Task<Void, Never>?
    private var workItem: DispatchWorkItem?
    private var globalMonitor: Any?
    private var localMonitor: Any?

    init() {
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.keyCode == 53, event.modifierFlags.intersection([.command, .control]).isEmpty == false else { return }
            Task { @MainActor in self?.stop() }
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.keyCode == 53, event.modifierFlags.intersection([.command, .control]).isEmpty == false else { return event }
            Task { @MainActor in self?.stop() }
            return nil
        }
    }

    deinit {
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
    }

    var accessibilityGranted: Bool { AXIsProcessTrusted() }

    @discardableResult
    func requestAccessibility() -> Bool {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
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
        let plan = TypingEngine.generatePlan(text: text, settings: settings, profile: profile)
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
        countdownTask?.cancel()
        countdownTask = nil
        workItem?.cancel()
        workItem = nil
        if resetState { state = .stopped }
    }

    func reset() { state = .ready }

    private func begin(_ plan: TypingPlan) {
        state = .typing
        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            let source = CGEventSource(stateID: .hidSystemState)
            for event in plan.events {
                guard self.workItem?.isCancelled == false else { return }
                Self.sleep(milliseconds: event.flight)
                guard self.workItem?.isCancelled == false else { return }
                Self.post(event, source: source)
            }
            DispatchQueue.main.async { [weak self] in
                guard let self, self.workItem?.isCancelled == false else { return }
                self.workItem = nil
                self.state = .complete
            }
        }
        workItem = item
        DispatchQueue.global(qos: .userInitiated).async(execute: item)
    }

    private nonisolated static func post(_ event: PlannedEvent, source: CGEventSource?) {
        let key: (code: CGKeyCode, shift: Bool)?
        switch event.kind {
        case .backspace: key = (51, false)
        case .arrowLeft: key = (123, false)
        case .arrowRight: key = (124, false)
        case .enter: key = (36, false)
        case .tab: key = (48, false)
        case .character: key = KeyboardMap.lookup(event.value)
        }

        if let key {
            let down = CGEvent(keyboardEventSource: source, virtualKey: key.code, keyDown: true)
            let up = CGEvent(keyboardEventSource: source, virtualKey: key.code, keyDown: false)
            if key.shift {
                down?.flags = .maskShift
                up?.flags = .maskShift
            }
            down?.post(tap: .cghidEventTap)
            sleep(milliseconds: event.dwell)
            up?.post(tap: .cghidEventTap)
        } else {
            postUnicode(event.value, source: source, dwell: event.dwell)
        }
    }

    private nonisolated static func postUnicode(_ string: String, source: CGEventSource?, dwell: Double) {
        var units = Array(string.utf16)
        guard !units.isEmpty else { return }
        let down = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true)
        let up = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false)
        units.withUnsafeMutableBufferPointer { buffer in
            down?.keyboardSetUnicodeString(stringLength: buffer.count, unicodeString: buffer.baseAddress)
            up?.keyboardSetUnicodeString(stringLength: buffer.count, unicodeString: buffer.baseAddress)
        }
        down?.post(tap: .cghidEventTap)
        sleep(milliseconds: dwell)
        up?.post(tap: .cghidEventTap)
    }

    private nonisolated static func sleep(milliseconds: Double) {
        let microseconds = useconds_t(min(8_000_000, max(0, milliseconds * 1_000)))
        usleep(microseconds)
    }
}

private enum KeyboardMap {
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
        let lower = Character(string.lowercased())
        if let code = base[lower] { return (code, character.isUppercase) }
        if let plain = shifted[character], let code = base[plain] { return (code, true) }
        return nil
    }
}
