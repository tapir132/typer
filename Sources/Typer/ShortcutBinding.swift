import AppKit
import Carbon.HIToolbox

// Based on Cadence's recorder: normalize state flags and preserve physical key codes.
struct ShortcutBinding: Codable, Equatable, Sendable {
    /// `nil` is a modifier-only chord such as ⌃⌥, fired when it is released.
    var keyCode: UInt16?
    var modifiersRawValue: UInt
    var keyLabel: String

    /// Caps Lock, Fn, and the numeric-pad flag describe keyboard state, not a
    /// shortcut. Comparing them made ⌃⌥Space fail whenever Caps Lock was on.
    static let shortcutModifiers: NSEvent.ModifierFlags = [.control, .option, .shift, .command]

    static let functionKeyLabels: [UInt16: String] = [
        122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6",
        98: "F7", 100: "F8", 101: "F9", 109: "F10", 103: "F11", 111: "F12",
        105: "F13", 107: "F14", 113: "F15", 106: "F16", 64: "F17", 79: "F18",
        80: "F19", 90: "F20"
    ]

    var isModifierOnly: Bool { keyCode == nil }

    var normalized: Self {
        Self(keyCode: keyCode, modifiersRawValue: modifiers.rawValue,
             keyLabel: isModifierOnly ? "" : String(keyLabel.prefix(24)))
    }

    var isValid: Bool {
        if let keyCode {
            guard keyCode <= 127, ![54, 55, 56, 57, 58, 59, 60, 61, 62, 63].contains(keyCode),
                  !keyLabel.isEmpty, !keyLabel.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else { return false }
            return Self.functionKeyLabels[keyCode] != nil || Self.hasPrimaryModifier(modifiers)
        }
        return Self.hasPrimaryModifier(modifiers)
    }

    func matches(_ other: Self) -> Bool { keyCode == other.keyCode && modifiers == other.modifiers }

    var modifiers: NSEvent.ModifierFlags {
        NSEvent.ModifierFlags(rawValue: modifiersRawValue).intersection(Self.shortcutModifiers)
    }

    var carbonModifiers: UInt32 {
        var flags: UInt32 = 0
        if modifiers.contains(.control) { flags |= UInt32(controlKey) }
        if modifiers.contains(.option) { flags |= UInt32(optionKey) }
        if modifiers.contains(.shift) { flags |= UInt32(shiftKey) }
        if modifiers.contains(.command) { flags |= UInt32(cmdKey) }
        return flags
    }

    var displayText: String {
        modifierGlyphs + keyLabel
    }

    var modifierGlyphs: String {
        var text = ""
        if modifiers.contains(.control) { text += "⌃" }
        if modifiers.contains(.option) { text += "⌥" }
        if modifiers.contains(.shift) { text += "⇧" }
        if modifiers.contains(.command) { text += "⌘" }
        return text
    }

    /// Function keys are valid on their own; any other key needs ⌃, ⌥, or ⌘ so
    /// ordinary typing cannot trigger playback controls.
    static func from(_ event: NSEvent) -> ShortcutBinding? {
        let modifiers = event.modifierFlags.intersection(shortcutModifiers)
        let isFunctionKey = functionKeyLabels[event.keyCode] != nil
        guard isFunctionKey || hasPrimaryModifier(modifiers) else { return nil }
        return ShortcutBinding(
            keyCode: event.keyCode,
            modifiersRawValue: modifiers.rawValue,
            keyLabel: label(for: event)
        )
    }

    /// Shift alone is tapped constantly while typing, so a chord needs ⌃, ⌥, or ⌘.
    static func modifierOnly(_ flags: NSEvent.ModifierFlags) -> ShortcutBinding? {
        let modifiers = flags.intersection(shortcutModifiers)
        guard hasPrimaryModifier(modifiers) else { return nil }
        return ShortcutBinding(keyCode: nil, modifiersRawValue: modifiers.rawValue, keyLabel: "")
    }

    private static func hasPrimaryModifier(_ modifiers: NSEvent.ModifierFlags) -> Bool {
        !modifiers.intersection([.control, .option, .command]).isEmpty
    }

    static func label(for event: NSEvent) -> String {
        let special: [UInt16: String] = [
            36: "Return", 48: "Tab", 49: "Space", 51: "Delete", 53: "Esc",
            115: "Home", 116: "Page Up", 117: "Forward Delete", 119: "End",
            121: "Page Down", 123: "←", 124: "→", 125: "↓", 126: "↑"
        ]
        if let label = special[event.keyCode] ?? functionKeyLabels[event.keyCode] { return label }
        return event.charactersIgnoringModifiers?.uppercased() ?? "Key \(event.keyCode)"
    }
}

enum ShortcutAction: UInt32, CaseIterable, Identifiable {
    case arm = 1, pause, skipWait, stop
    var id: UInt32 { rawValue }
    var title: String {
        switch self {
        case .arm: return "Arm typing"
        case .pause: return "Pause / resume"
        case .skipWait: return "Skip current wait"
        case .stop: return "Stop typing"
        }
    }
    var detail: String {
        switch self {
        case .arm: return "Starts the countdown while Typer is focused."
        case .pause: return "Works in any app while playback is active."
        case .skipWait: return "Skips the remaining long pause."
        case .stop: return "Ends playback and releases held keys."
        }
    }
}

struct ShortcutBindings: Codable, Equatable {
    var arm = ShortcutBinding(keyCode: 36, modifiersRawValue: NSEvent.ModifierFlags.command.rawValue, keyLabel: "Return")
    var pause = ShortcutBinding(keyCode: 35, modifiersRawValue: NSEvent.ModifierFlags([.command, .option]).rawValue, keyLabel: "P")
    var skipWait = ShortcutBinding(keyCode: 124, modifiersRawValue: NSEvent.ModifierFlags([.command, .option]).rawValue, keyLabel: "→")
    var stop = ShortcutBinding(keyCode: 53, modifiersRawValue: NSEvent.ModifierFlags.command.rawValue, keyLabel: "Esc")
    static let backupStop = ShortcutBinding(keyCode: 53, modifiersRawValue: NSEvent.ModifierFlags.control.rawValue, keyLabel: "Esc")

    subscript(_ action: ShortcutAction) -> ShortcutBinding {
        get {
            switch action { case .arm: return arm; case .pause: return pause; case .skipWait: return skipWait; case .stop: return stop }
        }
        set {
            switch action { case .arm: arm = newValue; case .pause: pause = newValue; case .skipWait: skipWait = newValue; case .stop: stop = newValue }
        }
    }

    func validationError(for binding: ShortcutBinding, action: ShortcutAction) -> String? {
        guard binding.isValid else { return "Use a function key or a shortcut with Control, Option, or Command." }
        if binding.matches(Self.backupStop) { return "Control–Esc is reserved for backup Stop." }
        if let other = ShortcutAction.allCases.first(where: { $0 != action && self[$0].matches(binding) }) {
            return "Already used for \(other.title.lowercased()). Choose another shortcut."
        }
        // Keep the app's essential menu commands reachable, including Escape to cancel recording.
        if binding.modifiers == .command, let code = binding.keyCode, [12, 43, 4, 46].contains(code) {
            return "That shortcut is used by a macOS menu command. Choose another."
        }
        if binding.keyCode == 44 && binding.modifiers == [.command, .shift] {
            return "Command–? opens the guide. Choose another shortcut."
        }
        return nil
    }
}

/// Modifier-only shortcuts fire on release, and only if no ordinary key or
/// mouse click was part of the chord. Typer's synthetic events are filtered by
/// the driver before reaching this state machine.
struct ModifierShortcutGesture {
    private var held: NSEvent.ModifierFlags = []
    private var usedKey = false

    mutating func cancelChord() { usedKey = true }
    mutating func reset() { held = []; usedKey = false }
    mutating func flagsChanged(_ flags: NSEvent.ModifierFlags) -> NSEvent.ModifierFlags? {
        let current = flags.intersection(ShortcutBinding.shortcutModifiers)
        if !current.isEmpty { held.formUnion(current); return nil }
        let completed = !usedKey && !held.isEmpty ? held : nil
        reset()
        return completed
    }
}
