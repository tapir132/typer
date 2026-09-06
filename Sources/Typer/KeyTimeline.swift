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

    init(event: PlannedEvent) {
        switch event.kind {
        case .backspace: code = 51
        case .wordBackspace: code = 51; option = true
        case .arrowLeft: code = 123
        case .arrowRight: code = 124
        case .shiftArrowLeft: code = 123; shift = true
        case .enter: code = 36
        case .tab: code = 48
        case .character:
            if let key = KeyboardMap.lookup(event.value) { code = key.code; shift = key.shift }
            else { code = 0; unicode = event.value }
        }
    }
}

/// Retains the v1 event encoding, but compiles signed flights onto one clock.
/// Editing commands, Unicode fallback, modifier changes and repeated physical
/// keys are barriers. These constraints take priority over a sampled overlap.
enum KeyTimeline {
    static func strokes(for events: [PlannedEvent]) -> [PlannedStroke] {
        var result: [PlannedStroke] = []
        result.reserveCapacity(events.count)
        var lastPress = 0.0
        var lastDwell = 0.0
        var latestRelease = 0.0
        var releasesByKey: [UInt16: Double] = [:]
        var prior: KeyDescriptor?
        for (index, event) in events.enumerated() {
            let key = KeyDescriptor(event: event)
            let dwell = event.dwell.isFinite ? min(500, max(10, event.dwell)) : 76
            let flight = event.flight.isFinite ? min(60_000, max(-500, event.flight)) : 100
            var press = index == 0 ? max(0, flight) : max(lastPress + 1, lastPress + lastDwell + flight)
            let barrier = event.kind != .character || !key.unicode.isEmpty ||
                (index > 0 && events[index - 1].kind != .character) ||
                prior.map { $0.shift != key.shift || $0.option != key.option || !$0.unicode.isEmpty } == true
            if barrier { press = max(press, latestRelease) }
            press = max(press, releasesByKey[key.code] ?? 0)
            let release = press + dwell
            result.append(PlannedStroke(eventIndex: index, pressOffset: press, releaseOffset: release))
            lastPress = press; lastDwell = dwell; prior = key
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
        return (normalized, strokes.map(\.releaseOffset).max() ?? 0)
    }
}

struct PhysicalKeyAction: Equatable {
    var code: UInt16
    var isDown: Bool
    var shift: Bool
    var option: Bool
    var unicode: String = ""
}

/// Owns the output ledger for one run. Cancellation and output share a lock:
/// once cancel returns, no later key-down from this run can be posted.
final class PlaybackSession: @unchecked Sendable {
    enum Outcome { case complete, cancelled, failed }
    private let condition = NSCondition()
    private var cancelled = false
    private var failed = false
    private var pressed: [Int: KeyDescriptor] = [:]
    private var shiftDown = false
    private var optionDown = false
    private let emit: (PhysicalKeyAction) -> Bool

    init(emit: @escaping (PhysicalKeyAction) -> Bool) { self.emit = emit }

    func cancel() {
        condition.lock()
        cancelled = true
        releaseAll()
        condition.broadcast()
        condition.unlock()
    }

    @discardableResult
    func perform(_ action: TimelineAction, events: [PlannedEvent]) -> Bool {
        condition.lock()
        defer { condition.unlock() }
        guard !cancelled, !failed, events.indices.contains(action.eventIndex) else { return false }
        let key = KeyDescriptor(event: events[action.eventIndex])
        if action.isDown {
            if key.shift && !shiftDown {
                shiftDown = true
                guard send(code: 56, down: true) else { return abort() }
            }
            if key.option && !optionDown {
                optionDown = true
                guard send(code: 58, down: true) else { return abort() }
            }
            // Register before emitting so an output failure still attempts key-up.
            pressed[action.eventIndex] = key
            guard send(code: key.code, down: true, unicode: key.unicode) else { return abort() }
        } else if let held = pressed.removeValue(forKey: action.eventIndex) {
            guard send(code: held.code, down: false, unicode: held.unicode) else {
                pressed[action.eventIndex] = held
                return abort()
            }
            if shiftDown && !pressed.values.contains(where: \.shift) {
                shiftDown = false
                guard send(code: 56, down: false) else { shiftDown = true; return abort() }
            }
            if optionDown && !pressed.values.contains(where: \.option) {
                optionDown = false
                guard send(code: 58, down: false) else { optionDown = true; return abort() }
            }
        }
        return true
    }

    func run(plan: TypingPlan) -> Outcome {
        let actions = KeyTimeline.actions(for: KeyTimeline.strokes(for: plan.events))
        let origin = ProcessInfo.processInfo.systemUptime
        defer {
            condition.lock(); releaseAll(); condition.unlock()
        }
        for action in actions {
            condition.lock()
            while !cancelled && !failed {
                let remaining = origin + action.offset / 1_000 - ProcessInfo.processInfo.systemUptime
                if remaining <= 0 { break }
                // Deadlines are recomputed from a monotonic clock, never accumulated sleeps.
                _ = condition.wait(until: Date(timeIntervalSinceNow: min(0.05, remaining)))
            }
            let canContinue = !cancelled && !failed
            condition.unlock()
            if !canContinue || !perform(action, events: plan.events) {
                condition.lock(); defer { condition.unlock() }
                return failed ? .failed : .cancelled
            }
        }
        condition.lock(); defer { condition.unlock() }
        return failed ? .failed : cancelled ? .cancelled : .complete
    }

    private func send(code: UInt16, down: Bool, unicode: String = "") -> Bool {
        emit(PhysicalKeyAction(code: code, isDown: down, shift: shiftDown, option: optionDown, unicode: unicode))
    }

    private func abort() -> Bool { failed = true; releaseAll(); return false }

    private func releaseAll() {
        for index in pressed.keys.sorted() {
            if let key = pressed[index] { _ = send(code: key.code, down: false, unicode: key.unicode) }
        }
        pressed.removeAll()
        if shiftDown { shiftDown = false; _ = send(code: 56, down: false) }
        if optionDown { optionDown = false; _ = send(code: 58, down: false) }
    }
}
