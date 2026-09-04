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
    private var activePresses: [UInt16: UUID] = [:]
    private var lastCharacterAt: Double?

    mutating func keyDown(keyCode: UInt16, characters: String, timestamp: Double, isRepeat: Bool) {
        guard !isRepeat else { return }
        if startedAt == nil { startedAt = timestamp }
        lastEventAt = timestamp

        if keyCode == 51 {
            records.append(TrainingKeyRecord(
                id: UUID(),
                kind: .backspace,
                key: "Backspace",
                expected: "",
                pressTime: timestamp,
                cursor: characterCount,
                sinceMistake: lastCharacterAt.map { max(0, timestamp - $0) }
            ))
            backspaceCount += 1
            return
        }

        guard !characters.isEmpty else { return }
        let id = UUID()
        records.append(TrainingKeyRecord(
            id: id,
            kind: .character,
            key: characters,
            expected: "",
            pressTime: timestamp,
            cursor: characterCount
        ))
        activePresses[keyCode] = id
        characterCount += 1
        lastCharacterAt = timestamp
    }

    mutating func keyUp(keyCode: UInt16, timestamp: Double) {
        guard let id = activePresses.removeValue(forKey: keyCode),
              let index = records.firstIndex(where: { $0.id == id }) else { return }
        records[index].dwell = max(0, timestamp - records[index].pressTime)
        lastEventAt = max(lastEventAt ?? timestamp, timestamp)
    }

    func makeSample() -> TrainingSample? {
        guard characterCount >= 2, let startedAt, let lastEventAt else { return nil }
        let duration = max(1, lastEventAt - startedAt)
        // Only the count is needed for gross WPM. The document text is never
        // reconstructed or persisted by the capture service.
        let lengthOnlyTarget = String(repeating: "x", count: characterCount)
        return TypingEngine.summarize(records: records, target: lengthOnlyTarget, duration: duration)
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

    var canSave: Bool { !isCapturing && characterCount >= Self.minimumCharacters && capturedSample != nil }

    @discardableResult
    func start() -> Bool {
        guard !isCapturing else { return true }
        guard CGPreflightListenEventAccess() else {
            notice = "Input Monitoring permission is required for Live capture."
            return false
        }

        discard()
        let mask = eventMask(for: .keyDown) | eventMask(for: .keyUp)
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
    }

    deinit { tearDownTap() }

    private func receive(type: CGEventType, event: CGEvent) {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let eventTap { CGEvent.tapEnable(tap: eventTap, enable: true) }
            return
        }
        guard isCapturing, !IsSecureEventInputEnabled() else { return }
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return }

        let flags = event.flags
        guard !flags.contains(.maskCommand), !flags.contains(.maskControl), !flags.contains(.maskSecondaryFn) else { return }
        let keyCode = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
        let timestamp = Double(event.timestamp) / 1_000_000

        switch type {
        case .keyDown:
            let characters = unicodeString(from: event)
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
        if let startedAt = accumulator.startedAt {
            elapsedMilliseconds = max(0, ProcessInfo.processInfo.systemUptime * 1_000 - startedAt)
        }
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
