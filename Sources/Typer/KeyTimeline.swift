import Foundation

struct PlannedStroke: Equatable {
    var eventIndex: Int
    var pressOffset: Double
    var releaseOffset: Double
}

struct TimelineAction: Equatable {
    var offset: Double
    var eventIndex: Int
    var isDown: Bool
}

struct KeyDescriptor: Equatable {
    var code: UInt16
    var shift: Bool = false
    var option: Bool = false
    var unicode: String = ""
    var prefix: [LayoutKey] = []

    init(event: PlannedEvent, layout: KeyboardLayout = .us) {
        switch event.kind {
        case .backspace: code = 51
        case .wordBackspace: code = 51; option = true
        case .arrowLeft: code = 123
        case .arrowRight: code = 124
        case .shiftArrowLeft: code = 123; shift = true
        case .enter: code = 36
        case .tab: code = 48
        case .character:
            if let keys = layout.sequence(for: event.value), let key = keys.last {
                code = key.code; shift = key.shift; option = key.option; prefix = Array(keys.dropLast())
            }
            else { code = 0; unicode = event.value }
        }
    }
}

/// Retains the v1 event encoding, but compiles signed flights onto one clock.
/// Editing commands, Unicode fallback, modifier changes and repeated physical
/// keys are barriers. These constraints take priority over a sampled overlap.
enum KeyTimeline {
    static func strokes(for events: [PlannedEvent], layout: KeyboardLayout = .us) -> [PlannedStroke] {
        var result: [PlannedStroke] = []
        result.reserveCapacity(events.count)
        var lastPress = 0.0
        var lastDwell = 0.0
        var latestRelease = 0.0
        var releasesByKey: [UInt16: Double] = [:]
        var prior: KeyDescriptor?
        var latestModifierRelease = 0.0
        for (index, event) in events.enumerated() {
            let key = KeyDescriptor(event: event, layout: layout)
            let dwell = event.dwell.isFinite ? min(500, max(10, event.dwell)) : 76
            let flight = event.flight.isFinite ? min(60_000, max(-500, event.flight)) : 100
            var press = index == 0 ? max(0, flight) : max(lastPress + 1, lastPress + lastDwell + flight)
            let barrier = event.kind != .character || !key.unicode.isEmpty ||
                (index > 0 && events[index - 1].kind != .character) || !key.prefix.isEmpty ||
                prior.map { $0.shift != key.shift || $0.option != key.option || !$0.unicode.isEmpty || !$0.prefix.isEmpty } == true
            let lead = modifierLead(dwell: dwell, modified: key.shift || key.option)
            let prefixTime = compositionDuration(key: key, dwell: dwell)
            if barrier || !key.prefix.isEmpty {
                press = max(press, max(latestRelease, latestModifierRelease) + lead + prefixTime)
            }
            if index == 0 { press = max(press, lead + prefixTime) }
            press = max(press, releasesByKey[key.code] ?? 0)
            let release = press + dwell
            result.append(PlannedStroke(eventIndex: index, pressOffset: press, releaseOffset: release))
            lastPress = press; lastDwell = dwell; prior = key
            latestModifierRelease = max(latestModifierRelease, release + modifierLag(dwell: dwell, modified: key.shift || key.option))
            latestRelease = max(latestRelease, release)
            releasesByKey[key.code] = release
        }
        return result
    }

    static func actions(for strokes: [PlannedStroke]) -> [TimelineAction] {
        strokes.flatMap { stroke in
            [TimelineAction(offset: stroke.pressOffset, eventIndex: stroke.eventIndex, isDown: true),
             TimelineAction(offset: stroke.releaseOffset, eventIndex: stroke.eventIndex, isDown: false)]
        }.sorted {
            if $0.offset != $1.offset { return $0.offset < $1.offset }
            if $0.isDown != $1.isDown { return !$0.isDown } // Release before repress at ties.
            return $0.eventIndex < $1.eventIndex
        }
    }

    static func normalized(_ events: [PlannedEvent]) -> (events: [PlannedEvent], duration: Double) {
        let strokes = strokes(for: events)
        var normalized = events
        for (index, stroke) in strokes.enumerated() {
            normalized[index].flight = stroke.pressOffset - (index == 0 ? 0 : strokes[index - 1].releaseOffset)
            normalized[index].dwell = stroke.releaseOffset - stroke.pressOffset
        }
        return (normalized, physicalActions(for: normalized).last?.scheduledOffset ?? 0)
    }

    // Bounded engineering defaults, scaled with the planned hold. These timings
    // are not claimed to be learned modifier/accent measurements.
    static func modifierLead(dwell: Double, modified: Bool) -> Double { modified ? min(32, max(12, dwell * 0.22)) : 0 }
    static func modifierLag(dwell: Double, modified: Bool) -> Double { modified ? min(24, max(8, dwell * 0.15)) : 0 }
    static func compositionDuration(key: KeyDescriptor, dwell: Double) -> Double {
        key.prefix.reduce(0) { total, prefix in
            total + modifierLead(dwell: dwell, modified: prefix.shift || prefix.option) + dwell +
                modifierLag(dwell: dwell, modified: prefix.shift || prefix.option) + max(40, dwell * 0.6)
        }
    }

    /// Extra physical keys have no logical event index: preview/text progress
    /// commits the accented character exactly once, on the final base-key down.
    static func physicalActions(for events: [PlannedEvent], layout: KeyboardLayout = .us) -> [PhysicalKeyAction] {
        struct Interval { var start: Double; var end: Double; var owner: Int }
        var output: [PhysicalKeyAction] = [], shifts: [Interval] = [], options: [Interval] = []
        func add(_ key: KeyDescriptor, press: Double, release: Double, owner: Int, prefix: Bool = false) {
            for down in [true, false] {
                output.append(PhysicalKeyAction(code: key.code, isDown: down, shift: key.shift, option: key.option,
                    unicode: key.unicode, eventIndex: prefix ? nil : owner, scheduledOffset: down ? press : release,
                    ownerIndex: owner, isCompositionPrefix: prefix))
            }
            let dwell = release - press
            let interval = Interval(start: press - modifierLead(dwell: dwell, modified: true),
                                    end: release + modifierLag(dwell: dwell, modified: true), owner: owner)
            if key.shift { shifts.append(interval) }
            if key.option { options.append(interval) }
        }
        for stroke in strokes(for: events, layout: layout) {
            let key = KeyDescriptor(event: events[stroke.eventIndex], layout: layout)
            let dwell = stroke.releaseOffset - stroke.pressOffset
            var time = stroke.pressOffset - modifierLead(dwell: dwell, modified: key.shift || key.option) - compositionDuration(key: key, dwell: dwell)
            for prefix in key.prefix {
                var descriptor = key
                descriptor.code = prefix.code; descriptor.shift = prefix.shift; descriptor.option = prefix.option
                descriptor.unicode = ""; descriptor.prefix = []
                time += modifierLead(dwell: dwell, modified: prefix.shift || prefix.option)
                add(descriptor, press: time, release: time + dwell, owner: stroke.eventIndex, prefix: true)
                time += dwell + modifierLag(dwell: dwell, modified: prefix.shift || prefix.option) + max(40, dwell * 0.6)
            }
            add(key, press: stroke.pressOffset, release: stroke.releaseOffset, owner: stroke.eventIndex)
        }
        func modifiers(_ intervals: [Interval], code: UInt16) {
            var merged: [Interval] = []
            for interval in intervals.sorted(by: { $0.start < $1.start }) {
                if let last = merged.last, interval.start <= last.end {
                    merged[merged.count - 1].end = max(last.end, interval.end)
                } else { merged.append(interval) }
            }
            for interval in merged {
                output.append(PhysicalKeyAction(code: code, isDown: true, shift: false, option: false,
                    scheduledOffset: interval.start, ownerIndex: interval.owner))
                output.append(PhysicalKeyAction(code: code, isDown: false, shift: false, option: false,
                    scheduledOffset: interval.end, ownerIndex: interval.owner))
            }
        }
        modifiers(shifts, code: 56); modifiers(options, code: 58)
        output.sort {
            if $0.scheduledOffset != $1.scheduledOffset { return $0.scheduledOffset! < $1.scheduledOffset! }
            if $0.isDown != $1.isDown { return !$0.isDown }
            return $0.code < $1.code
        }
        var shift = false, option = false
        for index in output.indices {
            if output[index].code == 56 { shift = output[index].isDown }
            if output[index].code == 58 { option = output[index].isDown }
            output[index].shift = shift; output[index].option = option
        }
        return output
    }

}

struct PhysicalKeyAction: Equatable {
    var code: UInt16
    var isDown: Bool
    var shift: Bool
    var option: Bool
    var unicode: String = ""
    // Diagnostic provenance, never used to alter the key's physical behavior.
    var eventIndex: Int? = nil
    var scheduledOffset: Double? = nil
    var ownerIndex: Int = 0
    var isCompositionPrefix = false
    var isCompositionCleanup = false
}

/// Owns the output ledger for one run. Cancellation and output share a lock:
/// once cancel returns, no later key-down from this run can be posted.
final class PlaybackSession: @unchecked Sendable {
    enum Outcome { case complete, cancelled, failed }
    private let condition = NSCondition()
    private var cancelled = false
    private var failed = false
    private var pressed: [UInt16: PhysicalKeyAction] = [:]
    private var compositionOwner: Int?
    private var rewindOwner: Int?
    private let layout: KeyboardLayout
    private var shiftDown = false
    private var optionDown = false
    private var paused = false
    private var origin: Double?
    private var pauseBegan: Double?
    private var suspended = 0.0
    private var skipped = 0.0
    private var waitOffset: Double?
    private let emit: (PhysicalKeyAction) -> Bool

    init(layout: KeyboardLayout = .us, emit: @escaping (PhysicalKeyAction) -> Bool) { self.layout = layout; self.emit = emit }

    func cancel() {
        condition.lock()
        cancelled = true
        releaseAll()
        condition.broadcast()
        condition.unlock()
    }

    func pause() {
        condition.lock(); defer { condition.unlock() }
        guard !paused, !cancelled, !failed else { return }
        paused = true
        pauseBegan = ProcessInfo.processInfo.systemUptime
        rewindOwner = compositionOwner
        releaseAll()
        condition.broadcast()
    }

    func resume() {
        condition.lock(); defer { condition.unlock() }
        guard paused, !cancelled, !failed else { return }
        if let pauseBegan { suspended += ProcessInfo.processInfo.systemUptime - pauseBegan }
        self.pauseBegan = nil
        paused = false
        condition.broadcast()
    }

    @discardableResult func skipWait() -> Bool {
        condition.lock(); defer { condition.unlock() }
        guard !paused, !cancelled, !failed, let waitOffset else { return false }
        let remaining = waitOffset - elapsed()
        guard remaining > 0 else { return false }
        skipped += remaining
        self.waitOffset = nil
        condition.broadcast()
        return true
    }

    // All scheduler clock fields are protected by condition.
    private func elapsed() -> Double {
        guard let origin else { return 0 }
        return max(0, (pauseBegan ?? ProcessInfo.processInfo.systemUptime) - origin - suspended + skipped)
    }

    @discardableResult
    func perform(_ action: PhysicalKeyAction) -> Bool {
        condition.lock(); defer { condition.unlock() }
        return performLocked(action)
    }

    private func performLocked(_ action: PhysicalKeyAction) -> Bool {
        guard !cancelled, !failed, !paused else { return false }
        let modifier = action.code == 56 || action.code == 58
        if action.isDown {
            // Pause releases held modifiers. Restore any needed by the next key
            // if its original modifier-down action preceded the pause.
            if !modifier {
                if action.shift && !shiftDown { shiftDown = true; guard sendModifier(56, down: true) else { return abort() } }
                if action.option && !optionDown { optionDown = true; guard sendModifier(58, down: true) else { return abort() } }
            }
            if action.code == 56 { shiftDown = true }
            if action.code == 58 { optionDown = true }
            pressed[action.code] = action
            var press = action; press.shift = shiftDown; press.option = optionDown
            guard emit(press) else { return abort() }
            if action.isCompositionPrefix { compositionOwner = action.ownerIndex }
            else if !modifier { compositionOwner = nil }
        } else if pressed.removeValue(forKey: action.code) != nil {
            if action.code == 56 { shiftDown = false }
            if action.code == 58 { optionDown = false }
            // A pause may have released another modifier in this chord.
            var release = action; release.shift = shiftDown; release.option = optionDown
            guard emit(release) else {
                pressed[action.code] = action
                if action.code == 56 { shiftDown = true }
                if action.code == 58 { optionDown = true }
                return abort()
            }
        }
        return true
    }

    func run(plan: TypingPlan, onStart: ((Double) -> Void)? = nil,
             onProgress: ((PlaybackProgress) -> Void)? = nil) -> Outcome {
        let actions = KeyTimeline.physicalActions(for: plan.events, layout: layout)
        let duration = actions.last?.scheduledOffset ?? 0
        var firstDown: [Int: Int] = [:]
        for (index, action) in actions.enumerated() where action.isDown && firstDown[action.ownerIndex] == nil {
            firstDown[action.ownerIndex] = index
        }
        let origin = ProcessInfo.processInfo.systemUptime
        condition.lock()
        self.origin = origin
        if paused { pauseBegan = origin }
        condition.unlock()
        onStart?(origin)
        defer {
            condition.lock(); releaseAll(); condition.unlock()
        }
        var lastReport = -Double.infinity
        var position = 0
        while position < actions.count {
            var restarted = false
            while true {
                condition.lock()
                if cancelled || failed {
                    let outcome: Outcome = failed ? .failed : .cancelled
                    condition.unlock()
                    return outcome
                }
                if !paused, let owner = rewindOwner,
                   let restart = actions.firstIndex(where: { $0.ownerIndex == owner }) {
                    suspended += max(0, elapsed() - (actions[restart].scheduledOffset ?? 0) / 1_000)
                    position = restart; rewindOwner = nil; restarted = true
                    condition.unlock(); break
                }
                let action = actions[position], offset = action.scheduledOffset ?? 0
                let remaining = offset / 1_000 - elapsed()
                let event = plan.events[action.ownerIndex]
                let longWait = firstDown[action.ownerIndex] == position && event.flight >= 1_000 && remaining > 0
                waitOffset = longWait ? offset / 1_000 : nil
                if !paused && remaining <= 0 {
                    let success = performLocked(action)
                    condition.unlock()
                    if !success { return .failed }
                    break
                }
                let progress = PlaybackProgress(fraction: Double(position) / Double(max(1, actions.count)),
                    remaining: max(0, duration / 1_000 - elapsed()), waitRemaining: max(0, remaining),
                    pauseKind: longWait ? event.pauseKind ?? (event.kind == .character ? .hesitation : .repair) : nil,
                    isPaused: paused)
                condition.unlock()
                let now = ProcessInfo.processInfo.systemUptime
                if now - lastReport >= 0.05 {
                    onProgress?(progress) // Outside the lock: callbacks may pause/cancel.
                    lastReport = now
                }
                condition.lock()
                if !cancelled && !failed {
                    let freshRemaining = offset / 1_000 - elapsed()
                    if paused || freshRemaining > 0 {
                        _ = condition.wait(until: Date(timeIntervalSinceNow: paused ? 0.05 : min(0.05, freshRemaining)))
                    }
                }
                condition.unlock()
            }
            if !restarted { position += 1 }
        }
        onProgress?(PlaybackProgress(fraction: 1))
        condition.lock(); defer { condition.unlock() }
        return failed ? .failed : cancelled ? .cancelled : .complete
    }

    private func sendModifier(_ code: UInt16, down: Bool) -> Bool {
        let action = PhysicalKeyAction(code: code, isDown: down, shift: shiftDown, option: optionDown)
        if down { pressed[code] = action } else { pressed.removeValue(forKey: code) }
        return emit(action)
    }

    private func abort() -> Bool { failed = true; releaseAll(); return false }

    private func releaseAll() {
        for code in pressed.keys.sorted() where code != 56 && code != 58 {
            if var action = pressed[code] {
                action.isDown = false; action.eventIndex = nil; action.scheduledOffset = nil
                action.shift = shiftDown; action.option = optionDown
                _ = emit(action)
            }
        }
        pressed.removeAll()
        if shiftDown { shiftDown = false; _ = sendModifier(56, down: false) }
        if optionDown { optionDown = false; _ = sendModifier(58, down: false) }
        if compositionOwner != nil {
            // Dismiss an unfinished accent before stopping/replaying it. The
            // production transport permits this only in the original field.
            compositionOwner = nil
            let down = PhysicalKeyAction(code: 53, isDown: true, shift: false, option: false, isCompositionCleanup: true)
            var up = down; up.isDown = false
            if !emit(down) { failed = true }
            if !emit(up) { failed = true }
        }
    }
}
