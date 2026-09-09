import Foundation
import Testing
@testable import Typer

struct BackgroundCaptureTests {
    @Test func hourOfScatteredTypingMatchesTheSameActiveBouts() throws {
        var compact = GlobalCaptureAccumulator(), background = GlobalCaptureAccumulator()
        for minute in 0..<60 {
            compact.breakSequence()
            type("the next message. ", into: &compact, startingAt: Double(minute) * 5_000)
            // No explicit boundary: capture must detect every minute-long gap.
            type("the next message. ", into: &background, startingAt: Double(minute) * 60_000)
        }
        background.expireIdle(at: 3_600_000)
        let active = try #require(compact.makeSample()), idle = try #require(background.makeSample())
        #expect(idle.wpm == active.wpm && abs(idle.wpm - 80) < 0.001)
        #expect(idle.liveCaptureActivity == active.liveCaptureActivity)
        #expect(idle.evidence == active.evidence)
        #expect(idle.digraphs == active.digraphs)
        #expect(GlobalTrainingCapture.isUsable(idle))
        #expect(idle.evidence?.pauses.isEmpty == true && idle.evidence?.pauseContexts == nil)
        #expect(background.isIdle(at: 3_600_000))
    }

    @Test func gapsBreakDigraphsCorrectionsAndPendingHolds() throws {
        var capture = GlobalCaptureAccumulator()
        type("word.", into: &capture, startingAt: 0)
        capture.keyDown(keyCode: 9, characters: "b", timestamp: 1_000, isRepeat: false)
        capture.expireIdle(at: 4_000)
        capture.keyUp(keyCode: 9, timestamp: 60_000) // Late release must stay missing.
        capture.keyDown(keyCode: 51, characters: "", timestamp: 60_050, isRepeat: false)
        capture.keyUp(keyCode: 51, timestamp: 60_130)
        type(" new words", into: &capture, startingAt: 61_000)
        let sample = try #require(capture.makeSample())
        #expect(capture.records.first { $0.key == "b" }?.dwell == nil)
        #expect(sample.evidence?.repairLatencies.isEmpty == true)
        #expect(sample.evidence?.deletionRuns == [1])
        #expect(sample.digraphs["b "] == nil)
        #expect(sample.evidence?.pairs.values.allSatisfy { $0.interval <= 2_500 } == true)
    }

    @Test func focusClicksAndScrollingCannotJoinTypingPace() throws {
        var capture = GlobalCaptureAccumulator()
        for index in 0..<10 {
            type("short note", into: &capture, startingAt: Double(index) * 10_000)
            // The listener sends this boundary for focus changes, clicks,
            // scrolling, Secure Input, sleep, and interruptions.
            capture.breakSequence()
        }
        let sample = try #require(capture.makeSample())
        #expect(abs(sample.wpm - 80) < 0.001)
        #expect(sample.evidence?.pairs.count == 90)
        #expect(sample.evidence?.pauses.isEmpty == true)
    }

    @Test func editingCountsAsActiveTimeButNavigationAndRepeatsDoNotBridgeIt() throws {
        var capture = GlobalCaptureAccumulator()
        type("ab", into: &capture, startingAt: 0, interval: 100)
        capture.edit(.wordDelete, keyCode: 51, timestamp: 200)
        capture.keyDown(keyCode: 8, characters: "c", timestamp: 300, isRepeat: false)
        #expect(capture.activity.activeMilliseconds == 300)
        #expect(capture.activity.timedCharacters == 2)
        #expect(capture.activity.wpm == 80)
        capture.edit(.navigation, keyCode: 123, timestamp: 400)
        capture.keyDown(keyCode: 2, characters: "d", timestamp: 2_000, isRepeat: false)
        #expect(capture.activity.activeMilliseconds == 300)
        capture.keyDown(keyCode: 2, characters: "d", timestamp: 2_050, isRepeat: true)
        capture.keyDown(keyCode: 14, characters: "e", timestamp: 2_100, isRepeat: false)
        #expect(capture.activity.activeMilliseconds == 300)
        #expect(capture.characterCount == 5)
        #expect(capture.backspaceCount == 1)
    }

    @Test func isolatedKeysCannotInventAFastTypingProfile() throws {
        var capture = GlobalCaptureAccumulator()
        for index in 0..<40 {
            type("x", into: &capture, startingAt: Double(index) * 60_000)
        }
        let sample = try #require(capture.makeSample())
        #expect(sample.liveCaptureActivity?.wpm == nil)
        #expect(sample.evidence?.pairs.count == 0)
        #expect(!GlobalTrainingCapture.isUsable(sample))
    }

    @Test func shortHesitationAndRolloverRemainMeasurable() throws {
        var capture = GlobalCaptureAccumulator()
        capture.keyDown(keyCode: 0, characters: "a", timestamp: 0, isRepeat: false)
        capture.keyDown(keyCode: 11, characters: "b", timestamp: 50, isRepeat: false)
        capture.keyUp(keyCode: 0, timestamp: 100)
        capture.keyUp(keyCode: 11, timestamp: 150)
        capture.keyDown(keyCode: 8, characters: "c", timestamp: 2_550, isRepeat: false)
        capture.keyUp(keyCode: 8, timestamp: 2_650)
        let sample = try #require(capture.makeSample())
        #expect(sample.evidence?.pairs.values.map(\.flight) == [-50, 2_400])
        #expect(capture.activity.activeMilliseconds == 2_550)
        #expect(capture.activity.timedCharacters == 2)
        #expect(sample.evidence?.pauses.isEmpty == true)
    }

    @Test func hourDeadlineIncludesIdleAndClockAdvances() {
        let start = ContinuousClock.now
        #expect(!GlobalTrainingCapture.sessionHasExpired(since: start, at: start.advanced(by: .seconds(3_599))))
        #expect(GlobalTrainingCapture.sessionHasExpired(since: start, at: start.advanced(by: .seconds(3_600))))
        // A delayed tick after sleep must expire immediately, without new keys.
        #expect(GlobalTrainingCapture.sessionHasExpired(since: start, at: start.advanced(by: .seconds(7_200))))
        #expect(GlobalTrainingCapture.elapsed(since: start, at: start.advanced(by: .milliseconds(250))) == 250)
    }

    @Test func malformedTimesAndLateReleasesCannotPolluteActivePace() {
        var capture = GlobalCaptureAccumulator()
        type("ab", into: &capture, startingAt: 100, interval: 100)
        let activity = capture.activity
        capture.keyDown(keyCode: 8, characters: "c", timestamp: .nan, isRepeat: false)
        capture.keyDown(keyCode: 8, characters: "c", timestamp: -1, isRepeat: false)
        capture.keyDown(keyCode: 8, characters: "c", timestamp: 50, isRepeat: false)
        capture.keyUp(keyCode: 1, timestamp: .infinity)
        capture.keyDown(keyCode: 2, characters: "d", timestamp: 2_000, isRepeat: false)
        #expect(capture.activity == activity)
        #expect(capture.characterCount == 3)
    }

    @Test func longSessionsHaveBoundedPreviewsStorageAndRecordCount() throws {
        var capture = GlobalCaptureAccumulator()
        for index in 0..<(GlobalCaptureAccumulator.maximumRecords + 4) {
            let code = UInt16(index % 2)
            capture.keyDown(keyCode: code, characters: code == 0 ? "a" : "s", timestamp: Double(index) * 100, isRepeat: false)
            capture.keyUp(keyCode: code, timestamp: Double(index) * 100 + 80)
        }
        #expect(capture.hasReachedRecordLimit)
        #expect(capture.records.count == GlobalCaptureAccumulator.maximumRecords)
        let preview = try #require(capture.makeSample(preview: true))
        let sample = try #require(capture.makeSample())
        #expect(preview.evidence?.characterCount == GlobalCaptureAccumulator.previewRecordLimit)
        #expect(preview.wpm == sample.wpm)
        #expect(sample.evidence?.pairs.count == GlobalCaptureAccumulator.maximumRecords - 1)
        #expect((sample.evidence?.pairs.values.count ?? 0) <= 512)
        #expect(try JSONEncoder().encode(sample).count < 200_000)
    }

    @Test func oldLiveDataKeepsTimingWithoutRestoringIdlePausesOrWallClockSpeed() throws {
        var capture = GlobalCaptureAccumulator()
        type(String(repeating: "some words. ", count: 8), into: &capture, startingAt: 0)
        var old = try #require(capture.makeSample())
        old.liveCaptureActivity = nil
        old.wpm = 2
        old.evidence?.pauses = [45_000, 50_000]
        old.evidence?.pauseContexts = ["sentence": PauseDistribution(opportunities: 40, pauseCount: 4, durations: [45_000, 50_000, 40_000], sessions: 3)]
        let data = try JSONEncoder().encode(old)
        let decoded = try JSONDecoder().decode(TrainingSample.self, from: data)
        #expect(!decoded.isLegacy && decoded.liveCaptureActivity == nil)
        let learned = TypingEngine.merge(samples: [decoded])
        #expect(learned.wpm == 80)
        #expect(learned.evidence?.pairs == old.evidence?.pairs)
        #expect(learned.evidence?.pauseContexts == nil && learned.evidence?.pauses.isEmpty == true)
        let report = TypingValidation.evaluate(samples: Array(repeating: decoded, count: 4), mode: .liveCapture, seeds: [17])
        #expect(!report.trials.isEmpty)
        #expect(report.trials.allSatisfy { $0.wpm == 80 })
        #expect(report.humanToHuman?.distributions.first { $0.name == "Pause ≥ 1 s" }?.wassersteinDistance == nil)
        #expect(report.trials.allSatisfy { $0.comparison.pauseRates?.allSatisfy { $0.referenceFrequency == nil } == true })
    }

    @Test func newActivityRoundTripsAndFreewriteStillLearnsPauses() throws {
        var capture = GlobalCaptureAccumulator()
        type("a ", into: &capture, startingAt: 0)
        type("word", into: &capture, startingAt: 2_000)
        let live = try #require(capture.makeSample())
        let reloaded = try JSONDecoder().decode(TrainingSample.self, from: JSONEncoder().encode(live))
        #expect(reloaded == live)
        #expect(live.evidence?.pauseContexts == nil)
        let freewrite = TypingEngine.summarize(records: capture.records, target: "a word", duration: 3_000, mode: .freewrite)
        #expect(freewrite.evidence?.pauseContexts?["word"]?.pauseCount == 1)
        #expect(freewrite.evidence?.pauses.isEmpty == false)
    }

    @Test func preexistingLiveProfileCannotReplayItsOldThinkingPauses() throws {
        var capture = GlobalCaptureAccumulator()
        type(String(repeating: "a message. ", count: 8), into: &capture, startingAt: 0)
        let sample = try #require(capture.makeSample())
        var profile = TypingEngine.merge(samples: [sample, sample, sample])
        profile.evidence?.pauses = [55_000, 50_000, 45_000]
        profile.evidence?.pauseContexts = ["sentence": PauseDistribution(opportunities: 100, pauseCount: 100,
                                                                       durations: [55_000, 50_000, 45_000], sessions: 3)]
        profile.wordPause = 2_000
        let stabilized = profile.stabilized(wpm: 80)
        #expect(stabilized.evidence?.pauseContexts == nil)
        #expect(stabilized.wordPause == TypingProfile.baseline(wpm: 80).wordPause)
        var settings = TypingSettings()
        settings.mode = .personal
        settings.wpm = 80
        settings.thoughtPauses = false
        var random = SeededGenerator(seed: 17)
        let plan = TypingEngine.generatePlan(text: String(repeating: "The next message. ", count: 50),
                                            settings: settings, profile: profile, using: &random)
        #expect(!plan.events.contains { $0.flight >= 10_000 })
    }

    private func type(_ text: String, into capture: inout GlobalCaptureAccumulator, startingAt start: Double, interval: Double = 150) {
        for (index, character) in text.enumerated() {
            let code = UInt16(index % 40)
            let at = start + Double(index) * interval
            capture.keyDown(keyCode: code, characters: String(character), timestamp: at, isRepeat: false)
            capture.keyUp(keyCode: code, timestamp: at + 80)
        }
    }
}
