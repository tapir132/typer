import AppKit
import Carbon
import CoreGraphics
import Foundation

/// Active pace uses contiguous press intervals, including deletion time. The
/// first key after a break is not counted as an instantaneous typed character.
struct CaptureActivity: Codable, Equatable {
    var activeMilliseconds = 0.0
    var timedCharacters = 0

    var wpm: Double? {
        guard activeMilliseconds.isFinite, activeMilliseconds > 0, timedCharacters > 0 else { return nil }
        let pace = 12_000 * Double(timedCharacters) / activeMilliseconds
        return pace.isFinite ? pace : nil
    }
}

struct GlobalCaptureAccumulator {
    // A conservative segmentation rule, not a measured boundary for thought.
    static let idleThreshold: Double = 2_500
    static let maximumRecords = 100_000
    static let previewRecordLimit = 2_000

    private(set) var records: [TrainingKeyRecord] = []
    private(set) var characterCount = 0
    private(set) var backspaceCount = 0
    private(set) var lastEventAt: Double?
    private(set) var activity = CaptureActivity()
    private(set) var revision = 0
    private var activePresses: [UInt16: Int] = [:]
    private var previousTypingPress: Double?

    var hasReachedRecordLimit: Bool { records.count >= Self.maximumRecords }

    mutating func keyDown(keyCode: UInt16, characters: String, timestamp: Double, isRepeat: Bool) {
        guard !isRepeat else { breakSequence(); return }
        if keyCode == 51 {
            append(kind: .backspace, key: "Backspace", keyCode: keyCode, timestamp: timestamp)
        } else {
            guard characters.count == 1, !characters.unicodeScalars.contains(where: {
                CharacterSet.controlCharacters.contains($0) && $0 != "\n" && $0 != "\t"
            }) else { breakSequence(); return }
            append(kind: .character, key: characters, keyCode: keyCode, timestamp: timestamp)
        }
    }

    private mutating func append(kind: TrainingKeyRecord.Kind, key: String, keyCode: UInt16, timestamp: Double) {
        guard !hasReachedRecordLimit, timestamp.isFinite, timestamp >= 0 else { breakSequence(); return }
        if let lastEventAt, timestamp < lastEventAt { breakSequence(); return }
        if let lastEventAt, timestamp - lastEventAt > Self.idleThreshold { breakSequence() }
        // Navigation and selection are counted as editing actions, but do not
        // join typing speed across cursor movement or an unrelated shortcut.
        let isTyping = kind == .character || kind == .backspace || kind == .wordDelete
        if !isTyping { breakSequence() }
        if isTyping, let prior = previousTypingPress {
            let delta = timestamp - prior
            if (15...Self.idleThreshold).contains(delta) {
                activity.activeMilliseconds += delta
                if kind == .character { activity.timedCharacters += 1 }
            } else if delta < 15 { breakSequence() }
        }
        guard !hasReachedRecordLimit else { return }
        lastEventAt = timestamp
        records.append(TrainingKeyRecord(id: UUID(), kind: kind, key: key, expected: "", pressTime: timestamp, cursor: 0))
        revision += 1
        activePresses[keyCode] = records.count - 1
        previousTypingPress = isTyping ? timestamp : nil
        if kind == .character { characterCount += 1 }
        if kind == .backspace || kind == .wordDelete { backspaceCount += 1 }
    }

    mutating func keyUp(keyCode: UInt16, timestamp: Double) {
        guard let index = activePresses.removeValue(forKey: keyCode), records.indices.contains(index) else { return }
        let dwell = timestamp - records[index].pressTime
        records[index].dwell = dwell.isFinite && (10...500).contains(dwell) ? dwell : nil
        revision += 1
        // Releases never extend active pace or restart the idle timer.
    }

    mutating func edit(_ kind: TrainingKeyRecord.Kind, keyCode: UInt16, timestamp: Double) {
        guard kind != .boundary else { breakSequence(); return }
        append(kind: kind, key: "", keyCode: keyCode, timestamp: timestamp)
    }

    mutating func breakSequence() {
        activePresses.removeAll()
        previousTypingPress = nil
        guard !hasReachedRecordLimit, let last = records.last, last.kind != .boundary else { return }
        records.append(TrainingKeyRecord(id: UUID(), kind: .boundary, key: "", expected: "", pressTime: last.pressTime, cursor: 0))
        revision += 1
    }

    func isIdle(at timestamp: Double) -> Bool {
        guard previousTypingPress != nil, let lastEventAt else { return true }
        return !timestamp.isFinite || timestamp - lastEventAt > Self.idleThreshold
    }

    mutating func expireIdle(at timestamp: Double) {
        if isIdle(at: timestamp) { breakSequence() }
    }

    func makeSample(preview: Bool = false) -> TrainingSample? {
        guard characterCount >= 2 else { return nil }
        let observed = preview ? Array(records.suffix(Self.previewRecordLimit)) : records
        // Count-only target: no document is reconstructed. The live fingerprint
        // uses a bounded recent window; Stop summarizes the full session once.
        let lengthOnlyTarget = String(repeating: "x", count: observed.count)
        var sample = TypingEngine.summarize(records: observed, target: lengthOnlyTarget,
                                            duration: max(1, activity.activeMilliseconds), mode: .liveCapture)
        sample.liveCaptureActivity = activity
        sample.wpm = activity.wpm ?? 0
        return sample
    }
}

/// Explicit, session-based global timing capture. The event tap is listen-only:
/// physical events continue directly to the active application unchanged.
final class GlobalTrainingCapture: ObservableObject {
    static let minimumCharacters = 35
    static let minimumTimingPairs = 20
    static let maximumDuration: Double = 60 * 60 * 1_000

    @Published private(set) var isCapturing = false
    @Published private(set) var characterCount = 0
    @Published private(set) var backspaceCount = 0
    @Published private(set) var elapsedMilliseconds: Double = 0
    @Published private(set) var secureInputActive = false
    @Published private(set) var isWaitingForTyping = true
    @Published private(set) var previewSample: TrainingSample?
    @Published private(set) var capturedSample: TrainingSample?
    @Published private(set) var notice: String?

    private var accumulator = GlobalCaptureAccumulator()
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var timer: Timer?
    private var captureBeganAt: ContinuousClock.Instant?
    private var lastPreviewAt: ContinuousClock.Instant?
    private var previewRevision = -1
    private var sessionObservers: [NSObjectProtocol] = []
    private var sessionIsActive = true
    private var systemIsAwake = true
    private var frontmostPID: pid_t?

    var canSave: Bool {
        !isCapturing && Self.isUsable(capturedSample)
    }

    static func isUsable(_ sample: TrainingSample?) -> Bool {
        sample?.mode == .liveCapture && (sample?.evidence?.characterCount ?? 0) >= minimumCharacters &&
            (sample?.evidence?.pairs.count ?? 0) >= minimumTimingPairs && sample?.liveCaptureActivity?.wpm != nil
    }

    var saveRequirement: String {
        characterCount < Self.minimumCharacters ? "At least 35 typed characters are needed."
            : "More consecutive typing is needed: record a few words with complete key releases."
    }

    static func elapsed(since start: ContinuousClock.Instant, at now: ContinuousClock.Instant) -> Double {
        let parts = start.duration(to: now).components
        return max(0, Double(parts.seconds) * 1_000 + Double(parts.attoseconds) / 1e15)
    }

    static func sessionHasExpired(since start: ContinuousClock.Instant, at now: ContinuousClock.Instant) -> Bool {
        elapsed(since: start, at: now) >= maximumDuration
    }

    @discardableResult
    func start() -> Bool {
        guard !isCapturing else { return true }
        guard CGPreflightListenEventAccess() else {
            notice = "Input Monitoring permission is required for Live capture."
            return false
        }

        discard()
        let mask = eventMask(for: .keyDown) | eventMask(for: .keyUp) | eventMask(for: .leftMouseDown) | eventMask(for: .rightMouseDown) | eventMask(for: .otherMouseDown) | eventMask(for: .scrollWheel)
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
        captureBeganAt = .now
        observeSessionChanges()
        frontmostPID = nil
        notice = nil

        let timer = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in self?.tick() }
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
        return true
    }

    func stop(automatic: Bool = false, recordLimit: Bool = false) {
        guard isCapturing else { return }
        tearDownTap()
        capturedSample = accumulator.makeSample()
        previewSample = capturedSample
        characterCount = accumulator.characterCount
        backspaceCount = accumulator.backspaceCount
        accumulator = GlobalCaptureAccumulator() // Drop raw keystrokes after summarizing.
        isCapturing = false
        captureBeganAt = nil
        secureInputActive = false
        isWaitingForTyping = true
        notice = recordLimit ? "This session reached its recording limit. Review and save it, then start another."
            : automatic ? "Capture finished after one hour. Review and save your sample." : nil
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
        isWaitingForTyping = true
        lastPreviewAt = nil
        previewRevision = -1
        sessionIsActive = true
        systemIsAwake = true
    }

    deinit { tearDownTap() }

    private func receive(type: CGEventType, event: CGEvent) {
        guard isCapturing, !checkSessionLimit() else { return }
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            accumulator.breakSequence()
            if let eventTap { CGEvent.tapEnable(tap: eventTap, enable: true) }
            return
        }
        let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier
        if pid != frontmostPID { accumulator.breakSequence(); frontmostPID = pid }
        guard sessionIsActive, systemIsAwake, !IsSecureEventInputEnabled(), pid != nil, pid != ProcessInfo.processInfo.processIdentifier else {
            accumulator.breakSequence(); return
        }
        if [.leftMouseDown, .rightMouseDown, .otherMouseDown, .scrollWheel].contains(type) { accumulator.breakSequence(); return }
        let flags = event.flags
        let keyCode = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
        let timestamp = Double(event.timestamp) / 1_000_000
        // Releases are matched before chord filtering; modifier flags may change
        // between a key's down and up.
        if type == .keyUp { accumulator.keyUp(keyCode: keyCode, timestamp: timestamp); return }
        let action = CaptureAction.classify(keyCode: keyCode, command: flags.contains(.maskCommand), control: flags.contains(.maskControl),
                                            option: flags.contains(.maskAlternate), shift: flags.contains(.maskShift), function: flags.contains(.maskSecondaryFn))
        let isRepeat = event.getIntegerValueField(.keyboardEventAutorepeat) != 0
        guard !isRepeat else { accumulator.breakSequence(); return }
        if let action {
            if action == .boundary { accumulator.breakSequence() }
            else { accumulator.edit(action, keyCode: keyCode, timestamp: timestamp) }
            backspaceCount = accumulator.backspaceCount
            if accumulator.hasReachedRecordLimit { stop(recordLimit: true) }
            return
        }
        switch type {
        case .keyDown:
            let characters = keyCode == 36 ? "\n" : keyCode == 48 ? "\t" : unicodeString(from: event)
            accumulator.keyDown(keyCode: keyCode, characters: characters, timestamp: timestamp, isRepeat: isRepeat)
            characterCount = accumulator.characterCount
            backspaceCount = accumulator.backspaceCount
            isWaitingForTyping = accumulator.isIdle(at: timestamp)
            if accumulator.hasReachedRecordLimit { stop(recordLimit: true) }
        case .keyUp:
            accumulator.keyUp(keyCode: keyCode, timestamp: timestamp)
        default:
            break
        }
    }

    private func tick() {
        guard isCapturing, !checkSessionLimit() else { return }
        if let captureBeganAt { elapsedMilliseconds = Self.elapsed(since: captureBeganAt, at: .now) }
        secureInputActive = IsSecureEventInputEnabled()
        let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier
        if !sessionIsActive || !systemIsAwake || secureInputActive || pid != frontmostPID || pid == ProcessInfo.processInfo.processIdentifier {
            accumulator.breakSequence(); frontmostPID = pid
        }
        accumulator.expireIdle(at: ProcessInfo.processInfo.systemUptime * 1_000)
        isWaitingForTyping = accumulator.isIdle(at: ProcessInfo.processInfo.systemUptime * 1_000)
        // Keep summarization out of the event tap and bounded even after an hour.
        let now = ContinuousClock.now
        if characterCount >= 2, accumulator.revision != previewRevision,
           lastPreviewAt.map({ Self.elapsed(since: $0, at: now) >= 2_000 }) ?? true {
            previewSample = accumulator.makeSample(preview: true)
            lastPreviewAt = now
            previewRevision = accumulator.revision
        }
    }

    @discardableResult private func checkSessionLimit() -> Bool {
        guard let captureBeganAt else { return false }
        let now = ContinuousClock.now
        guard Self.sessionHasExpired(since: captureBeganAt, at: now) else { return false }
        elapsedMilliseconds = Self.elapsed(since: captureBeganAt, at: now)
        stop(automatic: true)
        return true
    }

    private func observeSessionChanges() {
        let center = NSWorkspace.shared.notificationCenter
        sessionObservers.append(center.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] _ in
            self?.accumulator.breakSequence()
            self?.isWaitingForTyping = true
            self?.frontmostPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
        })
        for name in [NSWorkspace.willSleepNotification, NSWorkspace.sessionDidResignActiveNotification] {
            sessionObservers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                if name == NSWorkspace.willSleepNotification { self?.systemIsAwake = false }
                else { self?.sessionIsActive = false }
                self?.accumulator.breakSequence()
                self?.isWaitingForTyping = true
            })
        }
        for name in [NSWorkspace.didWakeNotification, NSWorkspace.sessionDidBecomeActiveNotification] {
            sessionObservers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                self?.accumulator.breakSequence()
                if name == NSWorkspace.didWakeNotification { self?.systemIsAwake = true }
                else { self?.sessionIsActive = true }
                self?.checkSessionLimit()
            })
        }
    }

    private func tearDownTap() {
        sessionObservers.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0) }
        sessionObservers.removeAll()
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
