import Foundation
import Testing
@testable import Typer

struct ValidationOverviewTests {
    private let text = String(repeating: "the quick fox ", count: 5)

    private func sample(mode: TrainingMode = .copy, completed: String? = nil) -> TrainingSample {
        let records = text.enumerated().map { index, character in
            TrainingKeyRecord(id: UUID(), kind: .character, key: String(character), expected: String(character),
                              pressTime: Double(index) * 120, dwell: 80, cursor: index)
        }
        return TypingEngine.summarize(records: records, target: text, duration: Double(text.count) * 120,
                                      mode: mode, completedText: completed)
    }

    @Test func referenceCompletionIsExplicitAndDoesNotInvalidateOlderSamples() throws {
        let complete = sample(completed: text)
        #expect(complete.referenceCompleted == true)
        #expect(sample(completed: String(text.prefix(20))).referenceCompleted == false)
        #expect(sample(mode: .sprint, completed: text + " extra").referenceCompleted == false)
        let freewrite = sample(mode: .freewrite, completed: text)
        #expect(freewrite.referenceText == nil && freewrite.referenceCompleted == nil)
        var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(complete)) as? [String: Any])
        object.removeValue(forKey: "referenceCompleted")
        let older = try JSONDecoder().decode(TrainingSample.self, from: JSONSerialization.data(withJSONObject: object))
        #expect(older.referenceCompleted == nil && !older.isLegacy)
        #expect(older.evidence == complete.evidence)
        let unknownReport = TypingValidation.evaluate(samples: Array(repeating: older, count: 4), seeds: [17])
        #expect(!unknownReport.trials.isEmpty && unknownReport.trials.allSatisfy { !$0.textMatched })
        let completeReport = TypingValidation.evaluate(samples: Array(repeating: complete, count: 4), seeds: [17])
        #expect(completeReport.trials.allSatisfy { $0.textMatched })
    }

    @Test func contextCanBeSelectedWithoutMixingTasksOrUsingLegacy() {
        let copy = sample(completed: text)
        let live = sample(mode: .liveCapture)
        var short = copy; short.evidence?.pairs = PairDistribution([TimingPair(interval: 120, priorDwell: 80)])
        var legacy = copy; legacy.mode = nil
        let samples = [copy, copy, short, copy, copy, legacy, live]
        let defaultReport = TypingValidation.evaluate(samples: samples, seeds: [17])
        #expect(defaultReport.eligibleSessions == 1 && defaultReport.trials.isEmpty)
        let copyReport = TypingValidation.evaluate(samples: samples, mode: .copy, seeds: [17])
        #expect(copyReport.eligibleSessions == 4)
        #expect(copyReport.trials.count == 4)
        #expect(copyReport.trials.allSatisfy { $0.trainingSessions == [1, 2] && [3, 4].contains($0.heldOutSession) })
        #expect(TypingValidation.eligibleSamples([legacy], mode: nil).isEmpty)
    }

    @Test func overviewPairsLikeTrialsAndDoesNotTurnMissingMetricsIntoZero() throws {
        let evidence = try #require(sample().evidence)
        let comparison = TypingValidation.compare(reference: evidence, candidate: evidence)
        func trial(seed: UInt64, mode: String, w1: Double, wpm: Double = 64) -> ValidationTrial {
            var comparison = comparison
            comparison.distributions[0].wassersteinDistance = w1
            return ValidationTrial(heldOutSession: 3, trainingSessions: [1, 2], seed: seed,
                                   mode: mode, wpm: wpm, textMatched: true, comparison: comparison)
        }
        let natural = TypingSettings.Mode.natural.rawValue, personal = TypingSettings.Mode.personal.rawValue
        let trials = [
            trial(seed: 17, mode: natural, w1: 10), trial(seed: 17, mode: personal, w1: 8),
            trial(seed: 41, mode: natural, w1: 100), trial(seed: 41, mode: personal, w1: 90),
            trial(seed: 89, mode: natural, w1: 30), trial(seed: 89, mode: personal, w1: 20),
            trial(seed: 90, mode: natural, w1: 900), // No partner.
            trial(seed: 91, mode: natural, w1: 901), trial(seed: 91, mode: personal, w1: 1, wpm: 100)
        ]
        let overview = TypingValidation.overview(trials: trials, humanToHuman: comparison)
        let hold = try #require(overview.first { $0.name == "Key hold" })
        #expect(hold.pairedTrials == 3)
        #expect(hold.naturalMedianW1 == 30 && hold.personalMedianW1 == 20)
        #expect(hold.naturalRange == [10, 100] && hold.personalRange == [8, 90])
        #expect(hold.humanToHumanW1 == 0)
        let pause = try #require(overview.first { $0.name == "Pause ≥ 1 s" })
        #expect(pause.pairedTrials == 0)
        #expect(pause.naturalMedianW1 == nil && pause.personalMedianW1 == nil && pause.humanToHumanW1 == nil)
    }

    @Test func invalidTimingGapEndsTheBurst() {
        let records = [0.0, 100, 200, 70_100, 70_200, 70_300].map {
            TrainingKeyRecord(id: UUID(), kind: .character, key: "a", expected: "", pressTime: $0, dwell: 80, cursor: 0)
        }
        let evidence = TimingEvidence.extract(records)
        #expect(evidence.excludedTransitionCount == 1)
        #expect(evidence.burstLengths == [3, 3])
        #expect(evidence.pairs.count == 4)
    }
}
