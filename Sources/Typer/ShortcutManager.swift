import AppKit
import ApplicationServices
import Carbon.HIToolbox
import Foundation

@MainActor
protocol ShortcutRegistering: AnyObject {
    var onPress: ((UInt32) -> Void)? { get set }
    func register(_ binding: ShortcutBinding, id: UInt32) -> Bool
    func unregister(_ id: UInt32)
}

/// Key chords use Carbon so macOS consumes them before the destination editor.
/// Only modifier-only chords need event monitors, as in Cadence.
@MainActor
final class SystemShortcutDriver: ShortcutRegistering {
    var onPress: ((UInt32) -> Void)?
    private static var nextSignature: UInt32 = 0x5459_5000
    private let signature: UInt32
    private var references: [UInt32: EventHotKeyRef] = [:]
    private var modifierBindings: [UInt32: ShortcutBinding] = [:]
    private var pressed: Set<UInt32> = []
    private var handler: EventHandlerRef?
    private var monitors: [Any] = []
    private var gesture = ModifierShortcutGesture()

    init() {
        Self.nextSignature &+= 1
        signature = Self.nextSignature
    }

    func register(_ binding: ShortcutBinding, id: UInt32) -> Bool {
        unregister(id)
        if let code = binding.keyCode {
            guard installHandler() else { return false }
            var reference: EventHotKeyRef?
            let status = RegisterEventHotKey(UInt32(code), binding.carbonModifiers,
                EventHotKeyID(signature: signature, id: id), GetEventDispatcherTarget(), 0, &reference)
            guard status == noErr, let reference else { return false }
            references[id] = reference
            return true
        }
        guard installMonitors() else { return false }
        modifierBindings[id] = binding
        gesture.reset()
        return true
    }

    func unregister(_ id: UInt32) {
        if let reference = references.removeValue(forKey: id) { UnregisterEventHotKey(reference) }
        modifierBindings.removeValue(forKey: id)
        pressed.remove(id)
        if modifierBindings.isEmpty {
            for monitor in monitors { NSEvent.removeMonitor(monitor) }
            monitors = []; gesture.reset()
        }
    }

    private func installHandler() -> Bool {
        if handler != nil { return true }
        let events = [
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased))
        ]
        let result = InstallEventHandler(GetEventDispatcherTarget(), { _, event, context in
            guard let context, let event else { return OSStatus(eventNotHandledErr) }
            var identifier = EventHotKeyID()
            guard GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                nil, MemoryLayout<EventHotKeyID>.size, nil, &identifier) == noErr else { return OSStatus(eventNotHandledErr) }
            return MainActor.assumeIsolated {
                let driver = Unmanaged<SystemShortcutDriver>.fromOpaque(context).takeUnretainedValue()
                guard identifier.signature == driver.signature, driver.references[identifier.id] != nil else { return OSStatus(eventNotHandledErr) }
                driver.receiveCarbon(id: identifier.id, isPress: GetEventKind(event) == UInt32(kEventHotKeyPressed))
                return noErr
            }
        }, events.count, events, Unmanaged.passUnretained(self).toOpaque(), &handler)
        return result == noErr && handler != nil
    }

    func receiveCarbon(id: UInt32, isPress: Bool) {
        if isPress {
            // A consumed Carbon key must also cancel a pending modifier-only chord.
            gesture.cancelChord()
            guard pressed.insert(id).inserted else { return }
            onPress?(id)
        } else { pressed.remove(id) }
    }

    private func installMonitors() -> Bool {
        if !monitors.isEmpty { return true }
        guard AXIsProcessTrusted() else { return false }
        let mask: NSEvent.EventTypeMask = [.flagsChanged, .keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown]
        let global = NSEvent.addGlobalMonitorForEvents(matching: mask) { [weak self] event in self?.receiveModifierEvent(event) }
        let local = NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self] event in
            self?.receiveModifierEvent(event); return event
        }
        monitors = [global, local].compactMap { $0 }
        guard monitors.count == 2 else {
            for monitor in monitors { NSEvent.removeMonitor(monitor) }
            monitors = []; return false
        }
        return true
    }

    private func receiveModifierEvent(_ event: NSEvent) {
        // Playback must never trigger its own controls through Shift/Option events.
        if event.cgEvent?.getIntegerValueField(.eventSourceUnixProcessID) == Int64(ProcessInfo.processInfo.processIdentifier) { return }
        if event.type == .flagsChanged {
            guard let chord = gesture.flagsChanged(event.modifierFlags),
                  let id = modifierBindings.first(where: { $0.value.modifiers == chord })?.key else { return }
            onPress?(id)
        } else { gesture.cancelChord() }
    }

    deinit {
        for reference in references.values { UnregisterEventHotKey(reference) }
        if let handler { RemoveEventHandler(handler) }
        for monitor in monitors { NSEvent.removeMonitor(monitor) }
    }
}

@MainActor
final class ShortcutManager: ObservableObject {
    @Published private(set) var bindings: ShortcutBindings
    @Published private(set) var errors: [ShortcutAction: String] = [:]
    @Published private(set) var recordingAction: ShortcutAction?
    @Published private(set) var backupAvailable = false
    @Published private(set) var playbackActive = false
    @Published private(set) var previewActive = false
    @Published private(set) var loadNotice: String?
    var onAction: ((ShortcutAction) -> Void)?
    var onBindingsChanged: (() -> Void)?

    private let defaults: UserDefaults
    private let driver: ShortcutRegistering
    private let persistenceKey = "typer.shortcuts.v1"
    private var registered: [UInt32: ShortcutBinding] = [:]
    private var observers: [NSObjectProtocol] = []
    private var appActive: Bool
    private let backupID: UInt32 = 5
    private let probeID: UInt32 = 99
    private var isStarted = false
    private var previewHandler: ((ShortcutAction) -> Void)?

    init(defaults: UserDefaults = .standard, driver: ShortcutRegistering? = nil) {
        self.defaults = defaults
        self.driver = driver ?? SystemShortcutDriver()
        appActive = NSApp?.isActive ?? false
        var saved = ShortcutBindings()
        if let data = defaults.data(forKey: persistenceKey) {
            if let decoded = try? JSONDecoder().decode(ShortcutBindings.self, from: data),
               ShortcutAction.allCases.allSatisfy({ decoded.validationError(for: decoded[$0], action: $0) == nil }) {
                saved = decoded
            } else { loadNotice = "Saved shortcuts could not be read. Default shortcuts are in use." }
        }
        for action in ShortcutAction.allCases { saved[action] = saved[action].normalized }
        bindings = saved
        self.driver.onPress = { [weak self] id in self?.trigger(id) }
    }

    func start() {
        guard !isStarted else { return }
        isStarted = true
        let center = NotificationCenter.default
        for name in [NSApplication.didBecomeActiveNotification, NSApplication.didResignActiveNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] notification in
                MainActor.assumeIsolated { self?.setAppActive(notification.name == NSApplication.didBecomeActiveNotification) }
            })
        }
        refreshRegistrations()
    }

    func setAppActive(_ active: Bool) {
        appActive = active
        refreshRegistrations()
    }

    private func trigger(_ id: UInt32) {
        guard recordingAction == nil, registered[id] != nil else { return }
        if previewActive {
            guard appActive else { return }
            if id == backupID { previewHandler?(.stop) }
            else if let action = ShortcutAction(rawValue: id) { previewHandler?(action) }
            return
        }
        if id == backupID { onAction?(.stop); return }
        guard let action = ShortcutAction(rawValue: id) else { return }
        if action == .arm && (!appActive || playbackActive) { return }
        if (action == .pause || action == .skipWait) && !playbackActive { return }
        onAction?(action)
    }

    func beginRecording(_ action: ShortcutAction) -> Bool {
        guard !playbackActive, !previewActive else { return false }
        recordingAction = action
        errors[action] = nil
        refreshRegistrations()
        return true
    }

    func endRecording(_ action: ShortcutAction) {
        guard recordingAction == action else { return }
        recordingAction = nil
        errors[action] = nil
        refreshRegistrations()
    }

    func perform(_ action: ShortcutAction) {
        guard recordingAction == nil else { return }
        if previewActive { previewHandler?(action) }
        else { onAction?(action) }
    }

    @discardableResult func setBinding(_ binding: ShortcutBinding, for action: ShortcutAction) -> String? {
        guard !playbackActive, !previewActive else { return "Stop playback before changing shortcuts." }
        let binding = binding.normalized
        if let error = bindings.validationError(for: binding, action: action) { errors[action] = error; return error }
        // Probe the actual OS registration before saving. Keep the old value on failure.
        if registered[action.rawValue] != nil { driver.unregister(action.rawValue); registered[action.rawValue] = nil }
        guard driver.register(binding, id: probeID) else {
            let error = registrationError(binding)
            errors[action] = error
            if recordingAction == nil { refreshRegistrations() }
            return error
        }
        driver.unregister(probeID)
        var updated = bindings
        updated[action] = binding
        guard let data = try? JSONEncoder().encode(updated) else { return "This shortcut could not be saved." }
        defaults.set(data, forKey: persistenceKey)
        bindings = updated; errors[action] = nil; loadNotice = nil
        onBindingsChanged?()
        if recordingAction == nil { refreshRegistrations() }
        return nil
    }

    func restoreDefaults() {
        guard !playbackActive, !previewActive, recordingAction == nil else { return }
        bindings = ShortcutBindings()
        defaults.removeObject(forKey: persistenceKey)
        errors = [:]; loadNotice = nil
        refreshRegistrations()
        onBindingsChanged?()
    }

    /// Check the real controls before the countdown, including a usable stop.
    func preparePlayback() -> String? {
        guard !previewActive else { return "Close the preview before arming typing." }
        guard recordingAction == nil else { return "Finish recording your shortcut before arming typing." }
        playbackActive = true
        refreshRegistrations()
        var failure: String?
        if registered[ShortcutAction.stop.rawValue] == nil && !backupAvailable {
            failure = "No Stop shortcut is available. Open Settings → Shortcuts and choose another Stop binding."
        } else if registered[ShortcutAction.pause.rawValue] == nil || registered[ShortcutAction.skipWait.rawValue] == nil {
            failure = "A playback shortcut is unavailable. Open Settings → Shortcuts to choose a free binding."
        }
        if failure != nil { finishPlayback() }
        return failure
    }

    func finishPlayback() { playbackActive = false; refreshRegistrations() }

    func beginPreview(_ handler: @escaping (ShortcutAction) -> Void) {
        guard !playbackActive, recordingAction == nil else { return }
        previewHandler = handler; previewActive = true
        refreshRegistrations()
    }

    func endPreview() {
        previewHandler = nil; previewActive = false
        refreshRegistrations()
    }

    var stopDescription: String {
        let primary = registered[ShortcutAction.stop.rawValue] != nil
        if primary && backupAvailable { return "\(bindings.stop.displayText) / \(ShortcutBindings.backupStop.displayText)" }
        if primary { return bindings.stop.displayText }
        if backupAvailable { return ShortcutBindings.backupStop.displayText }
        return isStarted ? "Stop shortcut unavailable" : "\(bindings.stop.displayText) / \(ShortcutBindings.backupStop.displayText)"
    }

    private func registrationError(_ binding: ShortcutBinding) -> String {
        binding.isModifierOnly
            ? "macOS couldn't enable this modifier shortcut. Check Accessibility permission or choose a key combination."
            : "\(binding.displayText) is unavailable or used by another app. Choose another shortcut."
    }

    private func refreshRegistrations() {
        guard isStarted else { return }
        var desired: [UInt32: ShortcutBinding] = [:]
        if recordingAction == nil {
            desired[ShortcutAction.stop.rawValue] = bindings.stop
            desired[backupID] = ShortcutBindings.backupStop
            if appActive && !playbackActive && !previewActive { desired[ShortcutAction.arm.rawValue] = bindings.arm }
            if playbackActive || (previewActive && appActive) {
                desired[ShortcutAction.pause.rawValue] = bindings.pause
                desired[ShortcutAction.skipWait.rawValue] = bindings.skipWait
            }
        }
        for (id, binding) in registered where desired[id]?.matches(binding) != true {
            driver.unregister(id); registered[id] = nil
        }
        for (id, binding) in desired.sorted(by: { $0.key < $1.key }) where registered[id] == nil {
            let success = driver.register(binding, id: id)
            if success { registered[id] = binding }
            if let action = ShortcutAction(rawValue: id) { errors[action] = success ? nil : registrationError(binding) }
        }
        backupAvailable = registered[backupID] != nil
    }

    deinit {
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
    }
}
