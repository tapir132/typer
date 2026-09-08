import Foundation

enum PauseContext: String, CaseIterable, Codable {
    case withinWord, word, sentence
    var label: String {
        switch self { case .withinWord: return "Within words"; case .word: return "Word boundaries"; case .sentence: return "Sentence boundaries" }
    }
}

struct PauseDistribution: Codable, Equatable {
    var opportunities = 0
    var pauseCount = 0
    var durations: [Double] = []
    var sessions = 1

    var validDurations: [Double] { durations.filter { $0.isFinite && (1_000...60_000).contains($0) } }
    // Engineering support gates, not a confidence probability or validation pass.
    var isSupported: Bool { opportunities >= 20 && pauseCount >= 3 && validDurations.count >= 3 && sessions >= 2 }
    var weight: Double {
        let n = Double(max(0, min(2_000, opportunities)))
        return min(0.9, n / (n + 40)) * min(1, Double(max(0, sessions)) / 3)
    }
    var frequency: Double { min(1, max(0, Double(pauseCount) / Double(max(1, opportunities)))) }

    mutating func observe(_ idle: Double) {
        guard idle.isFinite && (0...60_000).contains(idle) else { return }
        opportunities += 1
        if idle >= 1_000 { pauseCount += 1; durations.append(idle) }
    }
}

enum PauseLearning {
    /// The longest valid key-up-to-next-press idle across each boundary.
    /// Categorization is based on punctuation/spacing, not captured documents.
    static func extract(_ records: [TrainingKeyRecord]) -> [String: PauseDistribution] {
        var result: [String: PauseDistribution] = [:]
        var pending: PauseContext?
        var longest = 0.0
        let endings = Set<Character>(".!?。！？…")
        let closers = Set<Character>("\"'”’»)]}」』】")
        func whitespace(_ value: String) -> Bool { !value.isEmpty && value.allSatisfy(\.isWhitespace) }
        func closing(_ value: String) -> Bool { value.count == 1 && value.first.map { closers.contains($0) } == true }
        func terminal(_ value: String) -> Bool { value.count == 1 && value.first.map { endings.contains($0) } == true }
        for (prior, next) in zip(records, records.dropFirst()) {
            let interval = next.pressTime - prior.pressTime
            guard prior.kind == .character, next.kind == .character,
                  let hold = prior.dwell, hold.isFinite, (10...500).contains(hold),
                  interval.isFinite, (15...60_000).contains(interval) else {
                pending = nil; longest = 0; continue
            }
            let idle = max(0, interval - hold)
            let ends = prior.key.count == 1 && prior.key.first.map { endings.contains($0) } == true
            // Avoid treating the decimal point in 3.14 as a sentence boundary.
            if ends && (whitespace(next.key) || closing(next.key) || terminal(next.key) || prior.key != ".") {
                if pending != .sentence { longest = 0 }
                pending = .sentence
            } else if pending == nil && (whitespace(prior.key) || whitespace(next.key)) { pending = .word }
            if let context = pending {
                longest = max(longest, idle)
                if !whitespace(next.key) && !(context == .sentence && (closing(next.key) || terminal(next.key))) {
                    result[context.rawValue, default: PauseDistribution()].observe(longest)
                    pending = nil; longest = 0
                }
            } else if prior.key.first?.isLetter == true && next.key.first?.isLetter == true {
                result[PauseContext.withinWord.rawValue, default: PauseDistribution()].observe(idle)
            }
        }
        // An unfinished boundary contributes no invented observation.
        return result.mapValues {
            var value = $0
            value.durations = boundedSample(value.durations, limit: 128)
            return value
        }
    }

    static func merge(_ samples: [[String: PauseDistribution]]) -> [String: PauseDistribution] {
        var result: [String: PauseDistribution] = [:]
        for context in PauseContext.allCases {
            let observations = samples.compactMap { $0[context.rawValue] }.filter { $0.opportunities > 0 }
            guard !observations.isEmpty else { continue }
            var combined = PauseDistribution(); combined.sessions = observations.count
            for value in observations {
                let count = min(512, max(0, value.opportunities))
                combined.opportunities += count
                combined.pauseCount += Int((value.frequency * Double(count)).rounded())
                combined.durations += boundedSample(value.validDurations, limit: 32)
            }
            combined.durations = boundedSample(combined.durations, limit: 128)
            result[context.rawValue] = combined
        }
        return result
    }

    static func draw(_ distribution: PauseDistribution, baselineFrequency: Double, decision: Double,
                     selection: Double, length: Double) -> Double? {
        guard distribution.isSupported else { return nil }
        let frequency = baselineFrequency + (distribution.frequency - baselineFrequency) * distribution.weight
        guard decision < frequency else { return nil }
        let values = distribution.validDurations
        let observed = values[min(values.count - 1, Int(selection * Double(values.count)))]
        let fallback = 2_000 + length * 3_000
        return min(60_000, max(1_000, fallback + (observed - fallback) * distribution.weight))
    }
}
