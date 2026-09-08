import Foundation

enum PlaybackCheckScenario: String, CaseIterable, Identifiable, Codable {
    case rhythm = "Rhythm & overlap"
    case corrections = "Corrections"
    case unicode = "Punctuation & Unicode"
    var id: String { rawValue }

    var fixture: (text: String, plan: TypingPlan) {
        var events: [PlannedEvent] = []
        func type(_ text: String) {
            for character in text {
                let value = String(character)
                let kind: PlannedEventKind = value == "\n" ? .enter : value == "\t" ? .tab : .character
                let flight: Double = self == .rhythm && events.count % 3 != 0 ? -45 : 90
                events.append(PlannedEvent(kind: kind, value: value, flight: flight, dwell: 100))
            }
        }
        func key(_ kind: PlannedEventKind) {
            events.append(PlannedEvent(kind: kind, flight: 160, dwell: 75))
        }
        let expected: String
        switch self {
        case .rhythm:
            expected = "fjfj fjfj ABBA abba 1234!?"
            type(expected)
        case .corrections:
            type("The cax"); key(.backspace); type("t ")
            type("blue"); key(.wordBackspace); type("green ")
            type("cta")
            for _ in 0..<3 { key(.shiftArrowLeft) }
            type("cat ")
            type("ct"); key(.arrowLeft); type("a"); key(.arrowRight); type(".")
            expected = "The cat green cat cat."
        case .unicode:
            expected = "Typer: Aa!? 123\ncafé — 🙂\tOK"
            type(expected)
        }
        let normalized = KeyTimeline.normalized(events)
        return (expected, TypingPlan(events: normalized.events, duration: normalized.duration,
                                     repairs: self == .corrections ? 4 : 0,
                                     effectiveWPM: Int(Double(expected.count) / 5 / (normalized.duration / 60_000))))
    }
}

struct PlaybackReceipt: Codable, Equatable {
    var eventIndex: Int
    var isDown: Bool
    var code: UInt16
    var shift: Bool
    var option: Bool
    /// Both clocks are relative to the playback scheduler's monotonic origin.
    var eventOffset: Double
    var receiptOffset: Double
    var identity: Int { eventIndex * 2 + (isDown ? 0 : 1) }
}

struct PlaybackTimingError: Codable, Equatable {
    var name: String
    var count: Int
    var median: Double?
    var p95: Double?

    init(name: String, values: [Double]) {
        self.name = name
        let values = values.filter(\.isFinite).map(abs).sorted()
        count = values.count
        median = values.isEmpty ? nil : TypingEngine.median(values)
        // Nearest-rank descriptive percentile. No confidence interval is implied.
        p95 = values.isEmpty ? nil : values[max(0, Int(ceil(Double(values.count) * 0.95)) - 1)]
    }
}

struct PlaybackCheckReport: Codable {
    var schemaVersion = 1
    var createdAt = Date()
    var appVersion: String
    var systemVersion: String
    var inputSource: String
    var scenario: String
    var expectedText: String
    var receivedText: String
    var completed: Bool
    var interruption: String?
    var expectedEvents: Int
    var receivedEvents: Int
    var missingEvents: Int
    var duplicateEvents: Int
    var unexpectedEvents: Int
    var outOfOrderEvents: Int
    var modifierMismatches: Int
    var plannedRollover: Double?
    var receivedRollover: Double?
    var comparedCharacterPairs: Int
    var timingErrors: [PlaybackTimingError]
    var receipts: [PlaybackReceipt]
    var limitations = [
        "This is a controlled AppKit receiver inside Typer. It uses the production scheduler and event creation, with process-targeted delivery rather than the global HID route.",
        "Receipt times measure when Typer handles the event. Event timestamps describe event creation/occurrence and can conceal queue delays; both are retained.",
        "This does not measure physical keyboard latency or certify delivery in another application. Input layout, IME, autocorrect and editor shortcuts can change external results.",
        "Timing errors are descriptive milliseconds, with no universal pass threshold or probability of human typing. Repeat the check under representative system load.",
        "Only built-in test text and this run's tagged events are included. Results are kept in memory unless explicitly exported."
    ]

    var textMatches: Bool { Array(expectedText.utf8) == Array(receivedText.utf8) }
    var integrityPassed: Bool {
        completed && textMatches && missingEvents == 0 && duplicateEvents == 0 &&
            unexpectedEvents == 0 && outOfOrderEvents == 0 && modifierMismatches == 0
    }

    static func analyze(scenario: PlaybackCheckScenario, receipts: [PlaybackReceipt], text: String,
                        completed: Bool, interruption: String? = nil, inputSource: String = "Unknown") -> Self {
        let fixture = scenario.fixture
        let strokes = KeyTimeline.strokes(for: fixture.plan.events)
        let actions = KeyTimeline.actions(for: strokes)
        let ranks = Dictionary(uniqueKeysWithValues: actions.enumerated().map {
            ($0.element.eventIndex * 2 + ($0.element.isDown ? 0 : 1), $0.offset)
        })
        var accepted: [Int: PlaybackReceipt] = [:]
        var duplicates = 0, unexpected = 0, outOfOrder = 0, modifiers = 0, highestRank = -1
        var lateness: [Double] = [], queueDelay: [Double] = []
        for receipt in receipts {
            guard fixture.plan.events.indices.contains(receipt.eventIndex),
                  receipt.eventOffset.isFinite, receipt.receiptOffset.isFinite,
                  let rank = ranks[receipt.identity] else { unexpected += 1; continue }
            let key = KeyDescriptor(event: fixture.plan.events[receipt.eventIndex])
            guard receipt.code == key.code else { unexpected += 1; continue }
            guard accepted[receipt.identity] == nil else { duplicates += 1; continue }
            if rank < highestRank { outOfOrder += 1 }
            highestRank = max(highestRank, rank)
            if receipt.shift != key.shift || receipt.option != key.option { modifiers += 1 }
            accepted[receipt.identity] = receipt
            lateness.append(receipt.receiptOffset - actions[rank].offset)
            queueDelay.append(receipt.receiptOffset - receipt.eventOffset)
        }
        var holds: [Double] = [], intervals: [Double] = [], flights: [Double] = []
        var plannedOverlaps = 0, receivedOverlaps = 0
        for stroke in strokes {
            guard let down = accepted[stroke.eventIndex * 2], let up = accepted[stroke.eventIndex * 2 + 1] else { continue }
            holds.append((up.receiptOffset - down.receiptOffset) - (stroke.releaseOffset - stroke.pressOffset))
        }
        for (a, b) in zip(strokes, strokes.dropFirst()) {
            guard fixture.plan.events[a.eventIndex].kind == .character, fixture.plan.events[b.eventIndex].kind == .character,
                  let aDown = accepted[a.eventIndex * 2], let aUp = accepted[a.eventIndex * 2 + 1],
                  let bDown = accepted[b.eventIndex * 2] else { continue }
            intervals.append((bDown.receiptOffset - aDown.receiptOffset) - (b.pressOffset - a.pressOffset))
            flights.append((bDown.receiptOffset - aUp.receiptOffset) - (b.pressOffset - a.releaseOffset))
            if b.pressOffset < a.releaseOffset { plannedOverlaps += 1 }
            if bDown.receiptOffset < aUp.receiptOffset { receivedOverlaps += 1 }
        }
        return Self(appVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "Development",
                    systemVersion: ProcessInfo.processInfo.operatingSystemVersionString, inputSource: inputSource,
                    scenario: scenario.rawValue, expectedText: fixture.text, receivedText: text, completed: completed, interruption: interruption,
                    expectedEvents: actions.count, receivedEvents: receipts.count, missingEvents: actions.count - accepted.count,
                    duplicateEvents: duplicates, unexpectedEvents: unexpected, outOfOrderEvents: outOfOrder, modifierMismatches: modifiers,
                    plannedRollover: flights.isEmpty ? nil : Double(plannedOverlaps) / Double(flights.count),
                    receivedRollover: flights.isEmpty ? nil : Double(receivedOverlaps) / Double(flights.count), comparedCharacterPairs: flights.count,
                    timingErrors: [PlaybackTimingError(name: "Key hold", values: holds),
                                   PlaybackTimingError(name: "Press interval", values: intervals),
                                   PlaybackTimingError(name: "Signed flight", values: flights),
                                   PlaybackTimingError(name: "Arrival vs schedule", values: lateness),
                                   PlaybackTimingError(name: "Arrival vs event timestamp", values: queueDelay)],
                    receipts: receipts.filter { $0.eventOffset.isFinite && $0.receiptOffset.isFinite })
    }
}
