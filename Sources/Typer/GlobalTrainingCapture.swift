import AppKit
import Carbon
import CoreGraphics
import Foundation

struct GlobalCaptureAccumulator {
    private(set) var records: [TrainingKeyRecord] = []
    private(set) var characterCount = 0
    private(set) var backspaceCount = 0
    private(set) var startedAt: Double?
    private(set) var lastEventAt: Double?
    private var activePresses: [UInt16: Int] = [:]

    mutating func keyDown(keyCode: UInt16, characters: String, timestamp: Double, isRepeat: Bool) {
        guard !isRepeat else { breakSequence(); return }
        if startedAt == nil { startedAt = timestamp }
        lastEventAt = timestamp

        if keyCode == 51 {
            records.append(TrainingKeyRecord(
                id: UUID(),
                kind: .backspace,
                key: "Backspace",
                expected: "",
                pressTime: timestamp,
                cursor: characterCount
            ))
            activePresses[keyCode] = records.count - 1
            backspaceCount += 1
            return
        }

        guard characters.count == 1, !characters.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) && $0 != "\n" && $0 != "\t" }) else { breakSequence(); return }
        let id = UUID()
        records.append(TrainingKeyRecord(
            id: id,
            kind: .character,
            key: characters,
            expected: "",
            pressTime: timestamp,
            cursor: characterCount
        ))
        activePresses[keyCode] = records.count - 1
        characterCount += 1
    }

    mutating func keyUp(keyCode: UInt16, timestamp: Double) {
        guard let index = activePresses.removeValue(forKey: keyCode), records.indices.contains(index) else { return }
        let dwell = timestamp - records[index].pressTime
        records[index].dwell = dwell.isFinite && (0...500).contains(dwell) ? dwell : nil
        lastEventAt = max(lastEventAt ?? timestamp, timestamp)
    }

    mutating func edit(_ kind: TrainingKeyRecord.Kind, keyCode: UInt16, timestamp: Double) {
        if startedAt == nil { startedAt = timestamp }
        lastEventAt = timestamp
        records.append(TrainingKeyRecord(id: UUID(), kind: kind, key: "", expected: "", pressTime: timestamp, cursor: 0))
        activePresses[keyCode] = records.count - 1
        if kind == .wordDelete { backspaceCount += 1 }
    }

    mutating func breakSequence() {
        activePresses.removeAll()
        guard let last = records.last, last.kind != .boundary else { return }
        records.append(TrainingKeyRecord(id: UUID(), kind: .boundary, key: "", expected: "", pressTime: last.pressTime, cursor: 0))
    }

    func makeSample() -> TrainingSample? {
        guard characterCount >= 2, let startedAt, let lastEventAt else { return nil }
        let duration = max(1, lastEventAt - startedAt)
        // Only the count is needed for gross WPM. The document text is never
        // reconstructed or persisted by the capture service.
        let lengthOnlyTarget = String(repeating: "x", count: characterCount)
        return TypingEngine.summarize(records: records, target: lengthOnlyTarget, duration: duration, mode: .liveCapture)
    }
}

/// Explicit, session-based global timing capture. The event tap is listen-only:
/// physical events continue directly to the active application unchanged.
final class GlobalTrainingCapture: ObservableObject {
    static let minimumCharacters = 35
    static let maximumDuration: Double = 15 * 60 * 1_000

    @Published private(set) var isCapturing = false
    @Published private(set) var characterCount = 0
    @Published private(set) var backspaceCount = 0
    @Published private(set) var elapsedMilliseconds: Double = 0
    @Published private(set) var secureInputActive = false
    @Published private(set) var previewSample: TrainingSample?
    @Published private(set) var capturedSample: TrainingSample?
    @Published private(set) var notice: String?

    private var accumulator = GlobalCaptureAccumulator()
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var timer: Timer?
    private var captureBeganAt: Double?
    private var frontmostPID: pid_t?

    var canSave: Bool { !isCapturing && characterCount >= Self.minimumCharacters && capturedSample != nil }

    @discardableResult
    func start() -> Bool {
        guard !isCapturing else { return true }
        guard CGPreflightListenEventAccess() else {
            notice = "Input Monitoring permission is required for Live capture."
            return false
        }

        discard()
        let mask = eventMask(for: .keyDown) | eventMask(for: .keyUp) | eventMask(for: .leftMouseDown) | eventMask(for: .rightMouseDown)
        let callback: CGEventTapCallBack = { _, type, event, context in
            guard let context else { return Unmanaged.passUnretained(event) }
            let capture = Unmanaged<GlobalTrainingCapture>.fromOpaque(context).takeUnretainedValue()
            capture.receive(type: type, event: event)
            return Unmanaged.passUnretained(event)
        }
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: mask,
            callback: callback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            notice = "Live capture could not start. Enable Typer in Input Monitoring, then try again."
            return false
        }

        guard let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0) else {
            notice = "Live capture could not create its event listener."
            return false
        }
        eventTap = tap
        runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        isCapturing = true
        captureBeganAt = ProcessInfo.processInfo.systemUptime * 1_000
        frontmostPID = nil
        notice = nil

        let timer = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in self?.tick() }
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
        return true
    }

    func stop(automatic: Bool = false) {
        guard isCapturing else { return }
        tearDownTap()
        capturedSample = accumulator.makeSample()
        previewSample = capturedSample
        characterCount = accumulator.characterCount
        backspaceCount = accumulator.backspaceCount
        accumulator = GlobalCaptureAccumulator() // Drop raw keystrokes immediately.
        isCapturing = false
        captureBeganAt = nil
        secureInputActive = false
        notice = automatic ? "Capture stopped automatically after 15 minutes." : nil
    }

    func discard() {
        if isCapturing { tearDownTap() }
        accumulator = GlobalCaptureAccumulator()
        characterCount = 0
        backspaceCount = 0
        elapsedMilliseconds = 0
        secureInputActive = false
        previewSample = nil
        capturedSample = nil
        notice = nil
        isCapturing = false
        captureBeganAt = nil
        frontmostPID = nil
    }

    deinit { tearDownTap() }

    private func receive(type: CGEventType, event: CGEvent) {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            accumulator.breakSequence()
            if let eventTap { CGEvent.tapEnable(tap: eventTap, enable: true) }
            return
        }
        guard isCapturing else { return }
        let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier
        if pid != frontmostPID { accumulator.breakSequence(); frontmostPID = pid }
        guard !IsSecureEventInputEnabled(), pid != ProcessInfo.processInfo.processIdentifier else {
            accumulator.breakSequence(); return
        }
        if type == .leftMouseDown || type == .rightMouseDown { accumulator.breakSequence(); return }
        let flags = event.flags
        let keyCode = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
        let timestamp = Double(event.timestamp) / 1_000_000
        // Releases are matched before chord filtering; modifier flags may change
        // between a key's down and up.
        if type == .keyUp { accumulator.keyUp(keyCode: keyCode, timestamp: timestamp); return }
        let action = CaptureAction.classify(keyCode: keyCode, command: flags.contains(.maskCommand), control: flags.contains(.maskControl),
                                            option: flags.contains(.maskAlternate), shift: flags.contains(.maskShift), function: flags.contains(.maskSecondaryFn))
        if let action {
            if action == .boundary { accumulator.breakSequence() }
            else { accumulator.edit(action, keyCode: keyCode, timestamp: timestamp) }
            backspaceCount = accumulator.backspaceCount
            return
        }
        switch type {
        case .keyDown:
            let characters = keyCode == 36 ? "\n" : keyCode == 48 ? "\t" : unicodeString(from: event)
            let isRepeat = event.getIntegerValueField(.keyboardEventAutorepeat) != 0
            accumulator.keyDown(keyCode: keyCode, characters: characters, timestamp: timestamp, isRepeat: isRepeat)
            characterCount = accumulator.characterCount
            backspaceCount = accumulator.backspaceCount
            if characterCount >= 2, characterCount.isMultiple(of: 20) {
                previewSample = accumulator.makeSample()
            }
        case .keyUp:
            accumulator.keyUp(keyCode: keyCode, timestamp: timestamp)
        default:
            break
        }
    }

    private func tick() {
        guard isCapturing else { return }
        secureInputActive = IsSecureEventInputEnabled()
        let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier
        if secureInputActive || pid != frontmostPID { accumulator.breakSequence(); frontmostPID = pid }
        if let captureBeganAt { elapsedMilliseconds = max(0, ProcessInfo.processInfo.systemUptime * 1_000 - captureBeganAt) }
        if elapsedMilliseconds >= Self.maximumDuration { stop(automatic: true) }
    }

    private func tearDownTap() {
        timer?.invalidate()
        timer = nil
        if let eventTap { CGEvent.tapEnable(tap: eventTap, enable: false) }
        if let runLoopSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes) }
        runLoopSource = nil
        eventTap = nil
    }

    private func eventMask(for type: CGEventType) -> CGEventMask {
        CGEventMask(1) << type.rawValue
    }

    private func unicodeString(from event: CGEvent) -> String {
        var length = 0
        var buffer = [UniChar](repeating: 0, count: 8)
        event.keyboardGetUnicodeString(maxStringLength: buffer.count, actualStringLength: &length, unicodeString: &buffer)
        return String(utf16CodeUnits: buffer, count: length)
    }
}

/// Only action categories are learned from chords. Their text payload is ignored.
enum CaptureAction {
    static func classify(keyCode: UInt16, command: Bool, control: Bool, option: Bool, shift: Bool, function: Bool) -> TrainingKeyRecord.Kind? {
        if keyCode == 51 && option && !command && !control { return .wordDelete }
        if [123, 124, 125, 126, 115, 119, 116, 121].contains(keyCode) { return shift ? .selection : .navigation }
        if command && keyCode == 0 { return .selection } // Select All; no text retained.
        if command || control || function || option { return .boundary }
        return nil
    }
}
