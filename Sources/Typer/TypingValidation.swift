import Foundation

struct DistributionComparison: Codable, Equatable {
    var name: String
    var unit: String
    var referenceCount: Int
    var candidateCount: Int
    var referenceMedian: Double?
    var candidateMedian: Double?
    var referenceMAD: Double?
    var candidateMAD: Double?
    var ksDistance: Double?
    var wassersteinDistance: Double?
}

struct TraceComparison: Codable, Equatable {
    var distributions: [DistributionComparison]
    var referenceRollover: Double?
    var candidateRollover: Double?
    var referenceAutocorrelation: Double?
    var candidateAutocorrelation: Double?
    var referenceEditsPerCharacter: Double?
    var candidateEditsPerCharacter: Double?
    var referenceObservedPairs: Int
    var candidateObservedPairs: Int
    var referenceMissingHolds: Int
    var candidateMissingHolds: Int
}

struct ValidationTrial: Codable, Equatable {
    var heldOutSession: Int
    var trainingSessions: [Int]
    var seed: UInt64
    var mode: String
    var wpm: Double
    var textMatched: Bool
    var comparison: TraceComparison
}

struct ValidationReport: Codable, Equatable {
    var schemaVersion = 2
    var modelVersion = "paired-timing-v2"
    var createdAt: Date
    var context: String
    var eligibleSessions: Int
    var status: String
    var limitations: [String]
    var trials: [ValidationTrial]
    var humanToHuman: TraceComparison?
    var overview: [ValidationOverviewRow]? = nil
}

struct ValidationOverviewRow: Codable, Equatable {
    var name: String
    var unit: String
    var pairedTrials: Int
    var naturalMedianW1: Double?
    var personalMedianW1: Double?
    var humanToHumanW1: Double?
    var naturalRange: [Double]
    var personalRange: [Double]
}

enum TypingValidation {
    static let referenceText = "The morning light fell across the desk. I opened the notebook and wrote a few lines, then paused to read them again. Small changes made the message clearer, and there was still time to finish the next paragraph. "

    /// Descriptive distances only: no independence assumption, p-value or
    /// probability-of-humanity interpretation is attached to these statistics.
    static func distances(_ lhs: [Double], _ rhs: [Double]) -> (ks: Double, wasserstein: Double)? {
        let a = lhs.filter(\.isFinite).sorted(), b = rhs.filter(\.isFinite).sorted()
        guard !a.isEmpty, !b.isEmpty else { return nil }
        var i = 0, j = 0
        var previous = min(a[0], b[0]), ks = 0.0, area = 0.0
        while i < a.count || j < b.count {
            let x = min(i < a.count ? a[i] : .infinity, j < b.count ? b[j] : .infinity)
            let difference = abs(Double(i) / Double(a.count) - Double(j) / Double(b.count))
            area += difference * (x - previous)
            while i < a.count && a[i] == x { i += 1 }
            while j < b.count && b[j] == x { j += 1 }
            ks = max(ks, abs(Double(i) / Double(a.count) - Double(j) / Double(b.count)))
            previous = x
        }
        return (ks, area)
    }

    static func evidence(for plan: TypingPlan) -> TimingEvidence {
        let records = KeyTimeline.strokes(for: plan.events).map { stroke -> TrainingKeyRecord in
            let event = plan.events[stroke.eventIndex]
            let kind: TrainingKeyRecord.Kind
            switch event.kind {
            case .character, .enter, .tab: kind = .character
            case .backspace: kind = .backspace
            case .wordBackspace: kind = .wordDelete
            case .shiftArrowLeft: kind = .selection
            case .arrowLeft, .arrowRight: kind = .navigation
            }
            return TrainingKeyRecord(id: UUID(), kind: kind, key: event.value, expected: "", pressTime: stroke.pressOffset,
                                     dwell: stroke.releaseOffset - stroke.pressOffset, cursor: 0)
        }
        return TimingEvidence.extract(records)
    }

    static func compare(reference: TimingEvidence, candidate: TimingEvidence) -> TraceComparison {
        var distributions: [DistributionComparison] = []
        func add(_ name: String, _ a: [Double], _ b: [Double], unit: String = "ms") {
            let a = a.filter(\.isFinite), b = b.filter(\.isFinite)
            let distance = distances(a, b)
            distributions.append(DistributionComparison(name: name, unit: unit, referenceCount: a.count, candidateCount: b.count,
                referenceMedian: a.isEmpty ? nil : TypingEngine.median(a), candidateMedian: b.isEmpty ? nil : TypingEngine.median(b),
                referenceMAD: a.isEmpty ? nil : TypingEngine.mad(a), candidateMAD: b.isEmpty ? nil : TypingEngine.mad(b),
                ksDistance: distance?.ks, wassersteinDistance: distance?.wasserstein))
        }
        add("Key hold", reference.dwells, candidate.dwells)
        add("Press interval", reference.pairs.values.map(\.interval), candidate.pairs.values.map(\.interval))
        add("Signed flight", reference.pairs.values.map(\.flight), candidate.pairs.values.map(\.flight))
        add("Overlap duration", reference.pairs.values.filter { $0.flight < 0 }.map { -$0.flight }, candidate.pairs.values.filter { $0.flight < 0 }.map { -$0.flight })
        add("Pause ≥ 1 s", reference.pauses, candidate.pauses)
        add("Burst length (< 310 ms)", reference.burstLengths, candidate.burstLengths, unit: "keys")
        add("Deletion run", reference.deletionRuns, candidate.deletionRuns, unit: "actions")
        add("Pre-deletion interval", reference.repairLatencies, candidate.repairLatencies)
        for key in ["sameFinger", "sameHand", "alternatingHands", "other"] {
            add("QWERTY \(key)", reference.transitions[key]?.values.map(\.interval) ?? [], candidate.transitions[key]?.values.map(\.interval) ?? [])
        }
        for key in Set(reference.digraphPairs.keys).intersection(candidate.digraphPairs.keys).sorted() {
            guard let a = reference.digraphPairs[key], let b = candidate.digraphPairs[key], a.count >= 5, b.count >= 5 else { continue }
            add("Digraph \(key.debugDescription)", a.values.map(\.interval), b.values.map(\.interval))
        }
        func rate(_ evidence: TimingEvidence) -> Double? {
            guard evidence.characterCount > 0 else { return nil }
            return Double((evidence.editCounts["backspace"] ?? 0) + (evidence.editCounts["wordDelete"] ?? 0)) / Double(evidence.characterCount)
        }
        return TraceComparison(distributions: distributions, referenceRollover: reference.rolloverRate, candidateRollover: candidate.rolloverRate,
            referenceAutocorrelation: reference.intervalAutocorrelation, candidateAutocorrelation: candidate.intervalAutocorrelation,
            referenceEditsPerCharacter: rate(reference), candidateEditsPerCharacter: rate(candidate),
            referenceObservedPairs: reference.pairs.count, candidateObservedPairs: candidate.pairs.count,
            referenceMissingHolds: reference.missingDwellCount, candidateMissingHolds: candidate.missingDwellCount)
    }

    static func eligibleSamples(_ samples: [TrainingSample], mode: TrainingMode?) -> [TrainingSample] {
        samples.filter { !$0.isLegacy && $0.mode == mode && ($0.evidence?.pairs.count ?? 0) >= 20 }
    }

    static func evaluate(samples: [TrainingSample], mode: TrainingMode? = nil, seeds: [UInt64] = [17, 41, 89]) -> ValidationReport {
        let context = mode ?? samples.last?.mode
        let eligible = eligibleSamples(samples, mode: context)
        var report = ValidationReport(createdAt: Date(), context: context?.rawValue ?? "Unknown legacy context", eligibleSessions: eligible.count,
            status: "Not enough comparable sessions yet.",
            limitations: [
                "Distances describe stored, bounded observations; they are not a human probability or a significance test.",
                "Two latest sessions are held out together. Earlier sessions alone fit the personal model; each seed evaluates both modes at the same WPM.",
                "Report counts distinguish observed pairs from retained distribution values. Small counts, missing holds and task changes limit interpretation.",
                "Hold support: 10–500 ms; motor interval support: 15–2500 ms. Pauses: 1000–60000 ms. Burst threshold: 310 ms. These are engineering choices.",
                "Rollover denominator is eligible adjacent character pairs with a valid preceding hold. QWERTY finger classes are assumed.",
                "This evaluates planned timelines. Application delivery and realized OS timing require a separate receiver check."
            ], trials: [], humanToHuman: nil)
        report.limitations.append("Overview rows report median W1 and range across paired Natural/My rhythm trials with the same session, seed and WPM. Seeds share human sessions; they are not independent human replicates.")
        guard eligible.count >= 4 else { return report }
        let split = eligible.count - 2
        let training = Array(eligible.prefix(split).suffix(5))
        let profile = TypingEngine.merge(samples: training)
        let speed = min(180, max(20, profile.wpm))
        let first = eligible[split].evidence!, second = eligible[split + 1].evidence!
        report.humanToHuman = compare(reference: first, candidate: second)
        for index in split..<eligible.count {
            let heldOut = eligible[index]
            let text = heldOut.referenceText ?? String(repeating: referenceText, count: 3)
            for seed in seeds {
                for mode in [TypingSettings.Mode.natural, .personal] {
                    var settings = TypingSettings()
                    settings.mode = mode; settings.wpm = speed
                    var random = SeededGenerator(seed: seed)
                    let plan = TypingEngine.generatePlan(text: text, settings: settings,
                        profile: mode == .personal ? profile : .baseline(wpm: speed), using: &random)
                    report.trials.append(ValidationTrial(heldOutSession: index + 1,
                        trainingSessions: Array((max(0, split - 5) + 1)...split), seed: seed, mode: mode.rawValue, wpm: speed,
                        textMatched: heldOut.referenceText != nil && heldOut.referenceCompleted == true,
                        comparison: compare(reference: heldOut.evidence!, candidate: evidence(for: plan))))
                }
            }
        }
        report.status = "Two held-out sessions · \(training.count) training sessions · \(seeds.count) seeds per mode"
        if report.trials.contains(where: { !$0.textMatched }) {
            report.limitations.append("Some text is unmatched or completion is unverified. Freewrite/Live use a standard passage. Incomplete or older Copy/Sprint samples use their prompt without claiming the recorded text matched it. Content mix may explain differences.")
        }
        report.overview = overview(trials: report.trials, humanToHuman: report.humanToHuman)
        return report
    }

    static func overview(trials: [ValidationTrial], humanToHuman: TraceComparison?) -> [ValidationOverviewRow] {
        let natural = trials.filter { $0.mode == TypingSettings.Mode.natural.rawValue }
        let personal = trials.filter { $0.mode == TypingSettings.Mode.personal.rawValue }
        let names = ["Key hold", "Press interval", "Signed flight", "Overlap duration", "Pause ≥ 1 s",
                     "Burst length (< 310 ms)", "Deletion run", "Pre-deletion interval"]
        return names.map { name in
            var a: [Double] = [], b: [Double] = []
            var unit = "ms"
            for trial in natural {
                guard let match = personal.first(where: {
                    $0.heldOutSession == trial.heldOutSession && $0.seed == trial.seed && $0.wpm == trial.wpm &&
                        $0.textMatched == trial.textMatched && $0.trainingSessions == trial.trainingSessions
                }), let left = trial.comparison.distributions.first(where: { $0.name == name }),
                    let right = match.comparison.distributions.first(where: { $0.name == name }),
                    let x = left.wassersteinDistance, let y = right.wassersteinDistance,
                    x.isFinite, y.isFinite, left.unit == right.unit else { continue }
                unit = left.unit
                a.append(x); b.append(y)
            }
            let human = humanToHuman?.distributions.first(where: { $0.name == name })
            if a.isEmpty, let human { unit = human.unit }
            return ValidationOverviewRow(name: name, unit: unit, pairedTrials: a.count,
                naturalMedianW1: a.isEmpty ? nil : TypingEngine.median(a),
                personalMedianW1: b.isEmpty ? nil : TypingEngine.median(b), humanToHumanW1: human?.wassersteinDistance,
                naturalRange: a.isEmpty ? [] : [a.min()!, a.max()!], personalRange: b.isEmpty ? [] : [b.min()!, b.max()!])
        }
    }
}
