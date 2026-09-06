import Testing
import Foundation
@testable import Typer

struct RealismValidationTests {
    @Test func signedFlightsCompilePositiveZeroAndOverlap() {
        for flight in [40.0, 0.0, -40.0] {
            let events = [PlannedEvent(kind: .character, value: "f", flight: 0, dwell: 100),
                          PlannedEvent(kind: .character, value: "j", flight: flight, dwell: 70)]
            let strokes = KeyTimeline.strokes(for: events)
            #expect(strokes[1].pressOffset == 100 + flight)
            #expect(strokes[1].pressOffset - strokes[0].releaseOffset == flight)
            let actions = KeyTimeline.actions(for: strokes)
            #expect(actions.first?.isDown == true)
            if flight < 0 { #expect(actions[1].isDown) }
            if flight == 0 { #expect(!actions[1].isDown) }
        }
    }

    @Test func barriersProtectModifiersRepeatedKeysAndCorrections() {
        for pair in [("a", "A"), ("A", "a"), ("!", "b"), ("a", "a"), ("é", "a")] {
            let events = [PlannedEvent(kind: .character, value: pair.0, flight: 0, dwell: 100),
                          PlannedEvent(kind: .character, value: pair.1, flight: -60, dwell: 70)]
            let strokes = KeyTimeline.strokes(for: events)
            #expect(strokes[1].pressOffset >= strokes[0].releaseOffset)
        }
        let events = [PlannedEvent(kind: .character, value: "a", flight: 0, dwell: 200),
                      PlannedEvent(kind: .character, value: "b", flight: -170, dwell: 40),
                      PlannedEvent(kind: .backspace, flight: 0, dwell: 60)]
        let strokes = KeyTimeline.strokes(for: events)
        #expect(strokes[2].pressOffset >= 200)
        let shifted = [PlannedEvent(kind: .character, value: "A", flight: 0, dwell: 100),
                       PlannedEvent(kind: .character, value: "!", flight: -40, dwell: 80)]
        #expect(KeyTimeline.strokes(for: shifted)[1].pressOffset == 60)
    }

    @Test func durationIncludesTheLastReleaseEvenWhenItIsNotTheLastKey() {
        let events = [PlannedEvent(kind: .character, value: "f", flight: 0, dwell: 200),
                      PlannedEvent(kind: .character, value: "j", flight: -170, dwell: 40)]
        let normalized = KeyTimeline.normalized(events)
        #expect(normalized.duration == 200)
        #expect(normalized.events.reduce(0) { $0 + $1.flight + $1.dwell } == 70)
    }

    @Test func cancellationAtEveryActionReleasesAllOrdinaryKeysAndModifiers() {
        let events = [PlannedEvent(kind: .character, value: "A", flight: 0, dwell: 120),
                      PlannedEvent(kind: .character, value: "!", flight: -70, dwell: 130),
                      PlannedEvent(kind: .wordBackspace, flight: 40, dwell: 80),
                      PlannedEvent(kind: .character, value: "é", flight: 30, dwell: 60)]
        let actions = KeyTimeline.actions(for: KeyTimeline.strokes(for: events))
        for stop in 0...actions.count {
            var held: Set<UInt16> = []
            var output: [PhysicalKeyAction] = []
            let session = PlaybackSession { action in
                output.append(action)
                if action.isDown { held.insert(action.code) } else { held.remove(action.code) }
                return true
            }
            for action in actions.prefix(stop) { #expect(session.perform(action, events: events)) }
            session.cancel()
            #expect(held.isEmpty)
            let count = output.count
            for action in actions { #expect(!session.perform(action, events: events)) }
            #expect(output.count == count)
        }
    }

    @Test func failedOutputCleansUpOverlappingKeys() {
        var held: Set<UInt16> = []
        var downs = 0
        let events = [PlannedEvent(kind: .character, value: "A", flight: 0, dwell: 120),
                      PlannedEvent(kind: .character, value: "B", flight: -80, dwell: 120)]
        let session = PlaybackSession { action in
            if action.isDown { held.insert(action.code); downs += 1 }
            else { held.remove(action.code) }
            return !(action.isDown && downs == 3)
        }
        let actions = KeyTimeline.actions(for: KeyTimeline.strokes(for: events))
        #expect(session.perform(actions[0], events: events))
        #expect(!session.perform(actions[1], events: events))
        #expect(held.isEmpty)
    }

    @Test func runtimeUsesOverlappingAbsoluteDeadlines() {
        var output: [(PhysicalKeyAction, Double)] = []
        let session = PlaybackSession { action in output.append((action, ProcessInfo.processInfo.systemUptime)); return true }
        let events = [PlannedEvent(kind: .character, value: "f", flight: 0, dwell: 70),
                      PlannedEvent(kind: .character, value: "j", flight: -45, dwell: 70)]
        let plan = TypingPlan(events: events, duration: 95, repairs: 0, effectiveWPM: 0)
        #expect(session.run(plan: plan) == .complete)
        #expect(output.map { $0.0.isDown } == [true, true, false, false])
        #expect(output[1].1 < output[2].1)
        #expect(output.last!.1 - output.first!.1 >= 0.09)
    }

    @Test func extractorKeepsSignedPairsWithoutBridgingEditsOrGaps() {
        let records = [record("f", at: 0, hold: 120), record("j", at: 70, hold: 90),
                       TrainingKeyRecord(id: UUID(), kind: .backspace, key: "", expected: "", pressTime: 180, cursor: 0),
                       record("k", at: 250, hold: 90),
                       TrainingKeyRecord(id: UUID(), kind: .boundary, key: "", expected: "", pressTime: 300, cursor: 0),
                       record("a", at: 400, hold: 80)]
        let evidence = TimingEvidence.extract(records)
        #expect(evidence.pairs.count == 1)
        #expect(evidence.pairs.values[0].flight == -50)
        #expect(evidence.rolloverRate == 1)
        #expect(evidence.digraphPairs["jk"] == nil)
        #expect(evidence.digraphPairs["ka"] == nil)
        #expect(evidence.detectionDistances.isEmpty)
        #expect(evidence.deletionRuns == [1])
    }

    @Test func missingDataAndImpossibleTimingsAreNotPerfectEvidence() {
        let records = [record("a", at: 0, hold: nil), record("b", at: 100, hold: .nan), record("c", at: 100, hold: 90)]
        let evidence = TimingEvidence.extract(records)
        #expect(evidence.pairs.count == 0)
        #expect(evidence.rolloverRate == nil)
        #expect(evidence.intervalAutocorrelation == nil)
        #expect(evidence.missingDwellCount == 2)
        #expect(PairDistribution([TimingPair(interval: .infinity, priorDwell: 80)], count: 100_000).count == 0)
    }

    @Test func v1ProfilesAndSamplesDecodeWithoutLosingOriginalStatistics() throws {
        let profile = TypingProfile.baseline()
        let profileData = try JSONEncoder().encode(profile)
        let decodedProfile = try JSONDecoder().decode(TypingProfile.self, from: profileData)
        #expect(decodedProfile == profile)
        var sample = fixtureSample(hold: 95, interval: 100)
        sample.evidence = nil; sample.mode = nil; sample.capturedAt = nil; sample.referenceText = nil
        let data = try JSONEncoder().encode(sample)
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["evidence"] == nil)
        #expect(try JSONDecoder().decode(TrainingSample.self, from: data) == sample)
    }

    @Test func evidenceCountsDriveShrinkageAndSessionContributionIsBounded() {
        let short = fixtureSample(hold: 60, interval: 80, count: 5)
        let long = fixtureSample(hold: 120, interval: 200, count: 200)
        let merged = TypingEngine.merge(samples: [short, long])
        #expect(merged.dwellMedian == 120)
        #expect(merged.evidence!.pairs.count <= 132)
        var sparse = TypingEngine.merge(samples: [short])
        sparse.sampleCount = 99 // Sample count must not manufacture new evidence.
        let stable = sparse.stabilized(wpm: 64)
        #expect(abs(stable.dwellMedian - 76) < 2)
        let dense = TypingEngine.merge(samples: [long, long, long]).stabilized(wpm: 64)
        #expect(dense.dwellMedian > stable.dwellMedian + 20)
        #expect(PairDistribution([TimingPair(interval: 100, priorDwell: 80)]).confidence < 0.05)
    }

    @Test func learnedPairedTimingProducesRolloverAndCloserFixtureHolds() {
        let sample = fixtureSample(hold: 125, interval: 80, count: 300)
        let profile = TypingEngine.merge(samples: [sample, sample, sample])
        var settings = TypingSettings(); settings.wpm = 150; settings.mistakeLevel = 0; settings.thoughtPauses = false; settings.fatigueDrift = false
        let text = String(repeating: "fj", count: 150)
        var a = SeededGenerator(seed: 81), b = SeededGenerator(seed: 81)
        let personal = TypingValidation.evidence(for: TypingEngine.generatePlan(text: text, settings: settings, profile: profile, using: &a))
        let natural = TypingValidation.evidence(for: TypingEngine.generatePlan(text: text, settings: settings, profile: .baseline(wpm: 150), using: &b))
        #expect(personal.rolloverRate! > 0.5)
        let reference = sample.evidence!
        let personalDistance = TypingValidation.distances(reference.dwells, personal.dwells)!.wasserstein
        let naturalDistance = TypingValidation.distances(reference.dwells, natural.dwells)!.wasserstein
        #expect(personalDistance < naturalDistance)
        #expect(abs(personal.rolloverRate! - reference.rolloverRate!) < abs(natural.rolloverRate! - reference.rolloverRate!))
    }

    @Test func distancesHandleTiesUnequalSizesAndMissingValues() {
        let same = TypingValidation.distances([1, 1, 3], [1, 3, 1])!
        #expect(same.ks == 0 && same.wasserstein == 0)
        let shift = TypingValidation.distances([0, 0], [2, 2, 2])!
        #expect(shift.ks == 1 && shift.wasserstein == 2)
        let unequal = TypingValidation.distances([0, 2], [1])!
        #expect(unequal.ks == 0.5 && unequal.wasserstein == 1)
        #expect(TypingValidation.distances([], [1]) == nil)
        #expect(TypingValidation.distances([.nan, .infinity], [1]) == nil)
    }

    @Test func autocorrelationDetectsReorderingThatMarginalDistancesMiss() {
        let ordered = (0..<40).map { Double($0 * 10 + 100) }
        let shuffled = (0..<20).flatMap { [ordered[$0], ordered[39 - $0]] }
        #expect(TypingValidation.distances(ordered, shuffled)!.ks == 0)
        let original = lagCorrelation(Array(zip(ordered, ordered.dropFirst())))!
        let changed = lagCorrelation(Array(zip(shuffled, shuffled.dropFirst())))!
        #expect(original > 0.99 && changed < 0)
    }

    @Test func heldOutSessionsNeverTrainEitherComparison() throws {
        let samples = (0..<5).map { fixtureSample(hold: 100 + Double($0), interval: 110, count: 60) }
        let report = TypingValidation.evaluate(samples: samples, seeds: [41])
        #expect(report.trials.count == 4)
        #expect(report.trials.allSatisfy { $0.trainingSessions == [1, 2, 3] && !$0.trainingSessions.contains($0.heldOutSession) })
        #expect(Set(report.trials.map(\.heldOutSession)) == [4, 5])
        #expect(report.humanToHuman != nil)
        let rerun = TypingValidation.evaluate(samples: samples, seeds: [41])
        #expect(report.trials == rerun.trials)
        #expect(try JSONDecoder().decode(ValidationReport.self, from: JSONEncoder().encode(report)) == report)
        #expect(TypingValidation.evaluate(samples: Array(samples.prefix(3))).trials.isEmpty)
    }

    @Test func contextMismatchCannotBeSilentlyValidated() {
        var copy = fixtureSample(hold: 100, interval: 100)
        copy.mode = .copy
        var live = copy; live.mode = .liveCapture; live.referenceText = nil
        let report = TypingValidation.evaluate(samples: [copy, copy, copy, live])
        #expect(report.eligibleSessions == 1)
        #expect(report.trials.isEmpty)
    }

    @Test func globalCaptureBreaksFocusGapsAndTracksEditCategories() throws {
        var capture = GlobalCaptureAccumulator()
        capture.keyDown(keyCode: 3, characters: "f", timestamp: 0, isRepeat: false)
        capture.breakSequence()
        capture.keyUp(keyCode: 3, timestamp: 100)
        capture.keyDown(keyCode: 38, characters: "j", timestamp: 120, isRepeat: false)
        capture.keyUp(keyCode: 38, timestamp: 200)
        capture.edit(.wordDelete, keyCode: 51, timestamp: 300)
        let sample = try #require(capture.makeSample())
        #expect(sample.evidence?.pairs.count == 0)
        #expect(sample.evidence?.editCounts["wordDelete"] == 1)
        #expect(sample.confusions.isEmpty && sample.referenceText == nil)
        #expect(CaptureAction.classify(keyCode: 51, command: false, control: false, option: true, shift: false, function: false) == .wordDelete)
        #expect(CaptureAction.classify(keyCode: 123, command: false, control: false, option: true, shift: true, function: false) == .selection)
    }

    @MainActor @Test func deleteAllRemovesPersistedSamplesAndProfile() throws {
        let suite = "typer.tests.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = ProfileStore(defaults: defaults)
        store.add(sample: fixtureSample(hold: 100, interval: 120))
        #expect(store.samples.count == 1 && store.profiles.count == 1)
        store.deleteAllLearnedData()
        let reloaded = ProfileStore(defaults: defaults)
        #expect(reloaded.samples.isEmpty && reloaded.profiles.isEmpty)
        #expect(reloaded.activeProfileID == TypingProfile.baselineID)
    }

    @Test func reservoirRemainsBoundedAndDoesNotAliasAlternatingTiming() {
        let values = (0..<4096).map { $0 % 2 }
        let sampled = boundedSample(values, limit: 128)
        #expect(sampled.count == 128)
        #expect(Set(sampled) == [0, 1])
        #expect(sampled == boundedSample(values, limit: 128))
    }

    @Test func outputFlagsClearAfterShiftAndOption() {
        let events = [PlannedEvent(kind: .character, value: "A", flight: 0, dwell: 80),
                      PlannedEvent(kind: .character, value: "!", flight: -40, dwell: 80),
                      PlannedEvent(kind: .character, value: "a", flight: -40, dwell: 80),
                      PlannedEvent(kind: .wordBackspace, flight: 20, dwell: 80),
                      PlannedEvent(kind: .character, value: "b", flight: 20, dwell: 80)]
        var output: [PhysicalKeyAction] = []
        let session = PlaybackSession { output.append($0); return true }
        for action in KeyTimeline.actions(for: KeyTimeline.strokes(for: events)) { #expect(session.perform(action, events: events)) }
        let letters = output.filter { $0.isDown && $0.code != 56 && $0.code != 58 }
        #expect(letters.map(\.shift) == [true, true, false, false, false])
        #expect(letters.map(\.option) == [false, false, false, true, false])
        #expect(output.filter { $0.code == 56 && $0.isDown }.count == 1)
    }

    @Test func cancellationInterruptsAnExtendedPause() {
        let began = DispatchSemaphore(value: 0), finished = DispatchSemaphore(value: 0)
        let session = PlaybackSession { action in if action.isDown { began.signal() }; return true }
        let events = [PlannedEvent(kind: .character, value: "a", flight: 0, dwell: 100),
                      PlannedEvent(kind: .character, value: "b", flight: 45_000, dwell: 100)]
        let plan = TypingPlan(events: events, duration: 45_200, repairs: 0, effectiveWPM: 0)
        DispatchQueue.global().async { _ = session.run(plan: plan); finished.signal() }
        #expect(began.wait(timeout: .now() + 1) == .success)
        session.cancel()
        #expect(finished.wait(timeout: .now() + 0.5) == .success)
    }

    @Test func pathologicalProfilesStillProduceFiniteBoundedPlans() {
        var profile = TypingProfile.baseline()
        profile.sampleCount = 99; profile.dwellMedian = .nan; profile.intervalMAD = .infinity
        profile.medianInterval = .nan; profile.repairDelay = .infinity; profile.burstLength = .nan
        profile.digraphs = ["fj": [.nan, .infinity, -50]]
        var evidence = TimingEvidence()
        evidence.pairs = PairDistribution([TimingPair(interval: 100, priorDwell: 100)])
        evidence.pairs.values = [TimingPair(interval: .nan, priorDwell: .infinity)]
        evidence.pairs.count = Int.max
        profile.evidence = evidence
        var settings = TypingSettings(); settings.wpm = .nan; settings.variation = .nan
        var random = SeededGenerator(seed: 13)
        let plan = TypingEngine.generatePlan(text: "fj Fj! Because words remain intact.", settings: settings, profile: profile, using: &random)
        #expect(plan.duration.isFinite && plan.duration > 0)
        #expect(plan.events.allSatisfy { $0.flight.isFinite && $0.dwell.isFinite && $0.dwell > 0 && $0.dwell <= 250.001 })
    }

    @Test func fasterWPMShortensPlansAndFallbackTimingsAreSkewed() {
        let text = String(repeating: "fj ", count: 500)
        var settings = TypingSettings(); settings.mistakeLevel = 0; settings.fatigueDrift = false; settings.thoughtPauses = false
        settings.wpm = 40
        var a = SeededGenerator(seed: 29), b = SeededGenerator(seed: 29)
        let slow = TypingEngine.generatePlan(text: text, settings: settings, profile: .baseline(), using: &a)
        settings.wpm = 120
        let fast = TypingEngine.generatePlan(text: text, settings: settings, profile: .baseline(), using: &b)
        #expect(fast.duration < slow.duration * 0.6)
        let values = TypingValidation.evidence(for: slow).pairs.values.map(\.interval).sorted()
        let median = TypingEngine.median(values)
        #expect(values[Int(Double(values.count) * 0.9)] - median > median - values[Int(Double(values.count) * 0.1)])
    }

    private func record(_ key: String, at time: Double, hold: Double?) -> TrainingKeyRecord {
        TrainingKeyRecord(id: UUID(), kind: .character, key: key, expected: "", pressTime: time, dwell: hold, cursor: 0)
    }

    private func fixtureSample(hold: Double, interval: Double, count: Int = 100) -> TrainingSample {
        let text = String(repeating: "fj", count: (count + 1) / 2)
        let keys = Array(text)
        let records = (0..<count).map { record(String(keys[$0]), at: Double($0) * interval, hold: hold) }
        return TypingEngine.summarize(records: records, target: text, duration: Double(count) * interval, mode: .copy)
    }
}
