import Foundation
import Testing
@testable import Typer

struct PersonalTimingTests {
    @Test func predictiveMixtureKeepsPairedModesRatherThanAveragingTheirDraws() {
        let low = TimingPair(interval: 60, priorDwell: 110), high = TimingPair(interval: 220, priorDwell: 70)
        let distribution = PairDistribution([low, high], count: 120)
        let fallback = TimingPair(interval: 150, priorDwell: 80)
        #expect(distribution.sample(fallback: fallback, intervalScale: 1, draw: 0.1, pseudocount: 120) == low)
        #expect(distribution.sample(fallback: fallback, intervalScale: 1, draw: 0.4, pseudocount: 120) == high)
        #expect(distribution.sample(fallback: fallback, intervalScale: 1, draw: 0.6, pseudocount: 120) == fallback)
        var observed = [TimingPair]()
        for index in 0..<1000 { observed.append(distribution.sample(fallback: fallback, intervalScale: 1, draw: Double(index) / 1000, pseudocount: 120)) }
        #expect(observed.filter { $0 == low }.count == 250)
        #expect(observed.filter { $0 == high }.count == 250)
        #expect(observed.filter { $0 == fallback }.count == 500)
        let faster = distribution.sample(fallback: fallback, intervalScale: 0.8, draw: 0.1, pseudocount: 120)
        #expect(faster.interval == 48 && faster.priorDwell == 110)
    }

    @Test func personalPaceRetainsMotorIntervalsAtItsOwnRecordedWPM() {
        // A 60 WPM session can have fast 80 ms motor intervals and longer
        // thinking/correction gaps. Matching its WPM must not double those IKIs.
        let pair = TimingPair(interval: 80, priorDwell: 110)
        var evidence = TimingEvidence()
        evidence.pairs = PairDistribution([pair], count: 2000)
        evidence.digraphPairs = ["fj": evidence.pairs, "jf": evidence.pairs]
        evidence.transitions = ["alternatingHands": evidence.pairs]
        evidence.dwells = Array(repeating: 110, count: 256)
        var profile = TypingProfile.baseline(wpm: 60)
        profile.sampleCount = 5; profile.evidence = evidence; profile.dwellMedian = 110; profile.medianInterval = 80
        var settings = TypingSettings()
        settings.mode = .personal; settings.wpm = 60; settings.variation = 0
        settings.mistakeLevel = 0; settings.thoughtPauses = false; settings.fatigueDrift = false
        var random = SeededGenerator(seed: 17)
        let result = TypingValidation.evidence(for: TypingEngine.generatePlan(text: String(repeating: "fj", count: 200), settings: settings, profile: profile, using: &random))
        #expect(abs(TypingEngine.median(result.pairs.values.map(\.interval)) - 80) < 5)
        #expect((result.rolloverRate ?? 0) > 0.8)
    }
}
