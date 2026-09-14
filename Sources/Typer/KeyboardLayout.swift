import Carbon.HIToolbox
import Foundation

struct LayoutKey: Equatable, Sendable {
    var code: UInt16
    var shift = false
    var option = false
}

/// An immutable translation snapshot. Reading another installed layout never
/// selects it or changes the user's input source.
struct KeyboardLayout: Sendable {
    let identifier: String
    let name: String
    let mappings: [String: [LayoutKey]]

    private static var cachedUS: Self?
    static var us: Self {
        onMain {
            if let cachedUS { return cachedUS }
            let layout = installed(identifier: "com.apple.keylayout.US") ?? KeyboardLayout(identifier: "unavailable", name: "Unavailable", mappings: [:])
            cachedUS = layout; return layout
        }
    }

    private static func onMain<T>(_ work: () -> T) -> T {
        if Thread.isMainThread { return work() }
        return DispatchQueue.main.sync(execute: work)
    }

    static func currentIdentifier() -> String? {
        onMain {
            guard let source = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue() else { return nil }
            return string(source, kTISPropertyInputSourceID)
        }
    }

    static func current() -> Self? {
        if !Thread.isMainThread { return onMain { current() } }
        guard let source = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue() else { return nil }
        // Do not borrow an underlying Latin layout for an IME: the actual input
        // method can consume its keys differently.
        return read(source)
    }

    static func installed(identifier: String) -> Self? {
        if !Thread.isMainThread { return onMain { installed(identifier: identifier) } }
        let filter = [kTISPropertyInputSourceID as String: identifier] as CFDictionary
        guard let sources = TISCreateInputSourceList(filter, true)?.takeRetainedValue() as? [TISInputSource],
              let source = sources.first else { return nil }
        return read(source)
    }

    func sequence(for text: String) -> [LayoutKey]? {
        // Swift String equality is canonically equivalent. Physical composition
        // can normalize decomposed source bytes, so retain the Unicode fallback
        // unless this mapping reproduces the exact original UTF-8 sequence.
        guard let index = mappings.index(forKey: text),
              mappings[index].key.utf8.elementsEqual(text.utf8) else { return nil }
        return mappings[index].value
    }

    var directCharacters: [String: LayoutKey] {
        mappings.compactMapValues { $0.count == 1 ? $0[0] : nil }
    }

    private static func string(_ source: TISInputSource, _ key: CFString) -> String? {
        guard let property = TISGetInputSourceProperty(source, key) else { return nil }
        return Unmanaged<CFString>.fromOpaque(property).takeUnretainedValue() as String
    }

    private static func read(_ source: TISInputSource) -> Self? {
        guard let identifier = string(source, kTISPropertyInputSourceID),
              let property = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else { return nil }
        let data = Unmanaged<CFData>.fromOpaque(property).takeUnretainedValue()
        defer { withExtendedLifetime((data, source)) {} }
        guard CFDataGetLength(data) >= MemoryLayout<UCKeyboardLayout>.size,
              let bytes = CFDataGetBytePtr(data) else { return nil }
        let layout = UnsafeRawPointer(bytes).assumingMemoryBound(to: UCKeyboardLayout.self)
        // Do not prefer an ISO-only key on an ANSI keyboard just because the
        // layout resource can translate it. Return/Tab/editing stay separate.
        let shape = KBGetLayoutType(Int16(LMGetKbdType()))
        var codes = (UInt16(0)...50).filter { ![10, 36, 48].contains($0) }
        if shape == kKeyboardISO { codes.append(10) }
        if shape == kKeyboardJIS { codes += [93, 94] }
        let keys = [LayoutKey(code: 0), LayoutKey(code: 0, shift: true),
                    LayoutKey(code: 0, option: true), LayoutKey(code: 0, shift: true, option: true)]
            .flatMap { template in codes.map { LayoutKey(code: $0, shift: template.shift, option: template.option) } }
        func translate(_ key: LayoutKey, state: inout UInt32) -> String? {
            var length = 0, output = [UniChar](repeating: 0, count: 16)
            let flags = UInt32((key.shift ? shiftKey : 0) | (key.option ? optionKey : 0)) >> 8
            guard UCKeyTranslate(layout, key.code, UInt16(kUCKeyActionDown), flags,
                UInt32(LMGetKbdType()), 0, &state, output.count, &length, &output) == noErr, length > 0 else { return nil }
            let text = String(utf16CodeUnits: output, count: length)
            guard text.count == 1, !text.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else { return nil }
            return text
        }
        var mappings: [String: [LayoutKey]] = [:], dead: [(LayoutKey, UInt32)] = []
        for key in keys {
            var state: UInt32 = 0
            let text = translate(key, state: &state)
            if state != 0 { dead.append((key, state)) }
            else if let text, mappings[text] == nil { mappings[text] = [key] }
        }
        for (prefix, initial) in dead {
            for key in keys {
                var state = initial
                if let text = translate(key, state: &state), mappings[text] == nil {
                    // The state is opaque. On current macOS a completed accent
                    // can leave key-up bookkeeping (observed as 65536). Verify
                    // a following space is unchanged and clears the state;
                    // do not decode undocumented bits or assume nonzero=dead.
                    var probe = state
                    if translate(LayoutKey(code: 49), state: &probe) == " ", probe == 0 {
                        mappings[text] = [prefix, key]
                    }
                }
            }
        }
        return Self(identifier: identifier, name: string(source, kTISPropertyLocalizedName) ?? identifier, mappings: mappings)
    }
}

// Stable U.S. mapping for stored-plan normalization and the existing diagnostics.
// Live playback supplies its own current-layout snapshot.
enum KeyboardMap {
    static let directCharacters = KeyboardLayout.us.directCharacters
    static func lookup(_ string: String) -> LayoutKey? {
        guard let keys = KeyboardLayout.us.sequence(for: string), keys.count == 1 else { return nil }
        return keys[0]
    }
}

/// TIS must run on the main thread. Playback reads a small cached flag instead
/// of synchronously dispatching to main while holding the cancellation lock.
final class PlaybackLayoutGuard: @unchecked Sendable {
    private let lock = NSLock()
    private var matches = true
    private var observer: NSObjectProtocol?
    @MainActor init(identifier: String) {
        matches = KeyboardLayout.currentIdentifier() == identifier
        observer = DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name(kTISNotifySelectedKeyboardInputSourceChanged as String), object: nil, queue: .main) { [weak self] _ in
                let matches = KeyboardLayout.currentIdentifier() == identifier
                guard let self else { return }
                self.lock.lock(); self.matches = matches; self.lock.unlock()
            }
    }
    var isCurrent: Bool { lock.lock(); defer { lock.unlock() }; return matches }
    deinit { if let observer { DistributedNotificationCenter.default().removeObserver(observer) } }
}
