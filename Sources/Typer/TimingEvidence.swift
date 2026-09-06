import Foundation

struct TimingPair: Codable, Equatable {
    var interval: Double
    var priorDwell: Double
    var flight: Double { interval - priorDwell }
    var isValid: Bool {
        interval.isFinite && priorDwell.isFinite && (15...2_500).contains(interval) && (10...500).contains(priorDwell)
    }
}

struct PairDistribution: Codable, Equatable {
    var count: Int = 0
    var values: [TimingPair] = []

    init(_ values: [TimingPair] = [], count: Int? = nil, limit: Int = 256) {
        let valid = values.filter(\.isValid)
        self.values = boundedSample(valid, limit: limit)
        self.count = valid.isEmpty ? 0 : max(valid.count, count ?? valid.count)
    }

    var confidence: Double { min(0.95, Double(min(max(0, count), 2_000)) / Double(min(max(0, count), 2_000) + 24)) }
}

/// Derived timing observations only. No ordered character stream, document,
/// cursor positions, or raw key records are persisted here.
struct TimingEvidence: Codable, Equatable {
    var version = 2
    var characterCount = 0
    var pairs = PairDistribution()
    var transitions: [String: PairDistribution] = [:]
    var digraphPairs: [String: PairDistribution] = [:]
    var dwells: [Double] = []
    var pauses: [Double] = []
    var burstLengths: [Double] = []
    var deletionRuns: [Double] = []
    var repairLatencies: [Double] = []
    var detectionDistances: [Double] = []
    var editCounts: [String: Int] = [:]
    var intervalAutocorrelation: Double?
    var intervalCount = 0
    var missingDwellCount = 0
    var excludedTransitionCount = 0

    var rolloverRate: Double? {
        guard !pairs.values.isEmpty else { return nil }
        return Double(pairs.values.filter { $0.flight < 0 }.count) / Double(pairs.values.count)
    }

    static func extract(_ records: [TrainingKeyRecord]) -> TimingEvidence {
        var evidence = TimingEvidence()
        let characters = records.filter { $0.kind == .character }
        evidence.characterCount = characters.count
        let holds = characters.compactMap(\.dwell).filter { $0.isFinite && (10...500).contains($0) }
        evidence.dwells = boundedSample(holds, limit: 512)
        evidence.missingDwellCount = characters.count - holds.count
        var pairs: [TimingPair] = []
        var classes: [String: [TimingPair]] = [:]
        var digraphs: [String: [TimingPair]] = [:]
        var pauses: [Double] = []
        var bursts: [Double] = []
        var burst = 0
        var consecutiveIntervals: [Double] = []
        var lagPairs: [(Double, Double)] = []
        var previousInterval: Double?
        for (prior, current) in zip(records, records.dropFirst()) {
            guard prior.kind == .character, current.kind == .character else {
                previousInterval = nil
                if burst > 0 { bursts.append(Double(burst + 1)); burst = 0 }
                continue
            }
            let delta = current.pressTime - prior.pressTime
            guard delta.isFinite, delta >= 15, delta <= 60_000 else {
                evidence.excludedTransitionCount += 1
                previousInterval = nil
                continue
            }
            if delta >= 1_000 { pauses.append(delta) }
            if delta < 310 { burst += 1 }
            else { if burst > 0 { bursts.append(Double(burst + 1)) }; burst = 0 }
            if delta <= 2_500 {
                consecutiveIntervals.append(delta)
                if let previousInterval { lagPairs.append((previousInterval, delta)) }
                previousInterval = delta
            } else { previousInterval = nil }
            guard let hold = prior.dwell else { continue }
            let pair = TimingPair(interval: delta, priorDwell: hold)
            guard pair.isValid else { continue }
            pairs.append(pair)
            let transition = KeyboardTransition.classify(prior.key, current.key)
            classes[transition, default: []].append(pair)
            if let key = KeyboardTransition.digraph(prior.key, current.key) { digraphs[key, default: []].append(pair) }
        }
        if burst > 0 { bursts.append(Double(burst + 1)) }
        evidence.pairs = PairDistribution(pairs, limit: 512)
        evidence.transitions = classes.mapValues { PairDistribution($0, limit: 128) }
        evidence.digraphPairs = Dictionary(uniqueKeysWithValues: digraphs.sorted {
            $0.value.count == $1.value.count ? $0.key < $1.key : $0.value.count > $1.value.count
        }.prefix(256).map { ($0.key, PairDistribution($0.value, limit: 32)) })
        evidence.pauses = boundedSample(pauses, limit: 256)
        evidence.burstLengths = boundedSample(bursts, limit: 256)
        evidence.intervalCount = consecutiveIntervals.count
        evidence.intervalAutocorrelation = lagCorrelation(lagPairs)

        var deletionRun = 0
        var lastCharacter: TrainingKeyRecord?
        var mistakenAt: Int?
        var typedSinceMistake = 0
        for (index, record) in records.enumerated() {
            if record.kind != .character && record.kind != .boundary { evidence.editCounts[record.kind.rawValue, default: 0] += 1 }
            if record.kind == .backspace || record.kind == .wordDelete {
                if deletionRun == 0, let lastCharacter {
                    let latency = record.pressTime - lastCharacter.pressTime
                    if latency.isFinite && (0...10_000).contains(latency) { evidence.repairLatencies.append(latency) }
                }
                deletionRun += 1
                if mistakenAt != nil {
                    evidence.detectionDistances.append(Double(typedSinceMistake))
                    mistakenAt = nil
                }
            } else {
                if deletionRun > 0 { evidence.deletionRuns.append(Double(deletionRun)); deletionRun = 0 }
                if record.kind == .character {
                    if mistakenAt != nil { typedSinceMistake += 1 }
                    if mistakenAt == nil && !record.expected.isEmpty && record.key != record.expected {
                        mistakenAt = index; typedSinceMistake = 0
                    }
                    lastCharacter = record
                } else { lastCharacter = nil; mistakenAt = nil }
            }
        }
        if deletionRun > 0 { evidence.deletionRuns.append(Double(deletionRun)) }
        evidence.deletionRuns = boundedSample(evidence.deletionRuns, limit: 256)
        evidence.repairLatencies = boundedSample(evidence.repairLatencies, limit: 256)
        evidence.detectionDistances = boundedSample(evidence.detectionDistances, limit: 256)
        return evidence
    }

    static func merge(_ samples: [TimingEvidence]) -> TimingEvidence {
        var result = TimingEvidence()
        func mergePairs(_ distributions: [PairDistribution], limit: Int) -> PairDistribution {
            // A session contributes at most 128 observations per pool. Longer
            // sessions get more weight, but cannot drown all other sessions.
            let values = distributions.flatMap { boundedSample($0.values.filter(\.isValid), limit: 128) }
            let count = distributions.reduce(0) { $0 + min(128, max(0, $1.count)) }
            return PairDistribution(values, count: count, limit: limit)
        }
        result.characterCount = samples.reduce(0) { $0 + min(2_000, $1.characterCount) }
        result.pairs = mergePairs(samples.map(\.pairs), limit: 512)
        for key in Set(samples.flatMap { $0.transitions.keys }) {
            result.transitions[key] = mergePairs(samples.compactMap { $0.transitions[key] }, limit: 256)
        }
        for key in Set(samples.flatMap { $0.digraphPairs.keys }).sorted().prefix(256) {
            result.digraphPairs[key] = mergePairs(samples.compactMap { $0.digraphPairs[key] }, limit: 64)
        }
        func pool(_ path: KeyPath<TimingEvidence, [Double]>) -> [Double] {
            boundedSample(samples.flatMap { boundedSample($0[keyPath: path].filter(\.isFinite), limit: 128) }, limit: 512)
        }
        result.dwells = pool(\.dwells); result.pauses = pool(\.pauses); result.burstLengths = pool(\.burstLengths)
        result.deletionRuns = pool(\.deletionRuns); result.repairLatencies = pool(\.repairLatencies)
        result.detectionDistances = pool(\.detectionDistances)
        for sample in samples {
            for (key, count) in sample.editCounts { result.editCounts[key, default: 0] += min(2_000, max(0, count)) }
            result.missingDwellCount += sample.missingDwellCount
            result.excludedTransitionCount += sample.excludedTransitionCount
        }
        return result
    }
}

/// Conventional US QWERTY touch-typing classes; these are a fallback assumption,
/// not a measured claim about the user's actual finger assignment.
enum KeyboardTransition {
    static func classify(_ lhs: String, _ rhs: String) -> String {
        let fingers = ["qaz", "wsx", "edc", "rfvtgb", "yhnujm", "ik", "ol", "p"]
        guard lhs.count == 1, rhs.count == 1, let a = lhs.lowercased().first, let b = rhs.lowercased().first,
              let left = fingers.firstIndex(where: { $0.contains(a) }),
              let right = fingers.firstIndex(where: { $0.contains(b) }) else { return "other" }
        if left == right { return "sameFinger" }
        return (left < 4) == (right < 4) ? "sameHand" : "alternatingHands"
    }

    static func digraph(_ lhs: String, _ rhs: String) -> String? {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz .,!?;:'\n\t")
        let a = lhs.lowercased(), b = rhs.lowercased()
        guard a.utf16.count == 1, b.utf16.count == 1,
              a.unicodeScalars.allSatisfy({ allowed.contains($0) }), b.unicodeScalars.allSatisfy({ allowed.contains($0) }) else { return nil }
        return a + b
    }
}

func boundedSample<T>(_ values: [T], limit: Int) -> [T] {
    guard limit > 0 else { return [] }
    guard values.count > limit else { return values }
    // Seeded reservoir sampling avoids aliasing periodic typing patterns while
    // making saved summaries reproducible. Preserve sample order after selection.
    var selected = Array(0..<limit)
    var state: UInt64 = 0xA0761D6478BD642F
    for index in limit..<values.count {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        z ^= z >> 31
        let choice = Int(z % UInt64(index + 1))
        if choice < limit { selected[choice] = index }
    }
    return selected.sorted().map { values[$0] }
}

func lagCorrelation(_ pairs: [(Double, Double)]) -> Double? {
    guard pairs.count >= 3 else { return nil }
    let n = Double(pairs.count)
    let x = pairs.reduce(0) { $0 + $1.0 } / n, y = pairs.reduce(0) { $0 + $1.1 } / n
    let covariance = pairs.reduce(0) { $0 + ($1.0 - x) * ($1.1 - y) }
    let xx = pairs.reduce(0) { $0 + pow($1.0 - x, 2) }, yy = pairs.reduce(0) { $0 + pow($1.1 - y, 2) }
    guard xx > 0, yy > 0 else { return nil }
    return max(-1, min(1, covariance / sqrt(xx * yy)))
}
