import Foundation
import Testing
@testable import Typer

struct PlaybackControlsTests {
    private func plan(_ events: [PlannedEvent]) -> TypingPlan {
        let normalized = KeyTimeline.normalized(events)
        return TypingPlan(events: normalized.events, duration: normalized.duration, repairs: 0, effectiveWPM: 0)
    }

    @Test func pauseAtEveryActionReleasesKeysAndResumeDoesNotRepeatText() {
        let events = [
            PlannedEvent(kind: .character, value: "A", flight: 0, dwell: 120),
            PlannedEvent(kind: .character, value: "!", flight: -70, dwell: 130),
            PlannedEvent(kind: .wordBackspace, flight: 40, dwell: 80),
            PlannedEvent(kind: .character, value: "é", flight: 30, dwell: 60)
        ]
        let actions = KeyTimeline.actions(for: KeyTimeline.strokes(for: events))
        for split in 0...actions.count {
            var held: Set<UInt16> = [], output: [PhysicalKeyAction] = []
            let session = PlaybackSession {
                output.append($0)
                if $0.isDown { held.insert($0.code) } else { held.remove($0.code) }
                return true
            }
            for action in actions.prefix(split) { #expect(session.perform(action, events: events)) }
            session.pause()
            #expect(held.isEmpty)
            let count = output.count
            for action in actions.dropFirst(split) { #expect(!session.perform(action, events: events)) }
            #expect(output.count == count)
            #expect(!session.skipWait())
            session.resume()
            for action in actions.dropFirst(split) { #expect(session.perform(action, events: events)) }
            #expect(held.isEmpty)
            #expect(output.filter { $0.isDown && $0.eventIndex != nil }.compactMap(\.eventIndex) == Array(events.indices))
        }
    }

    @Test func pauseFreezesDeadlineAndCancelWorksWhilePaused() {
        let waiting = DispatchSemaphore(value: 0), finished = DispatchSemaphore(value: 0)
        let session = PlaybackSession { _ in true }
        let plan = plan([PlannedEvent(kind: .character, value: "a", flight: 5_000, dwell: 50)])
        var observed: [Double] = []
        DispatchQueue.global().async {
            _ = session.run(plan: plan, onProgress: { progress in
                if observed.isEmpty { session.pause() }
                if progress.isPaused { observed.append(progress.remaining); waiting.signal() }
                else { observed.append(progress.remaining) }
            })
            finished.signal()
        }
        #expect(waiting.wait(timeout: .now() + 1) == .success)
        #expect(waiting.wait(timeout: .now() + 1) == .success)
        session.cancel()
        #expect(finished.wait(timeout: .now() + 1) == .success)
        #expect(observed.count >= 3)
        #expect(abs(observed[observed.count - 1] - observed[observed.count - 2]) < 0.001)
    }

    @Test func skipOnlyShortensCurrentLongWaitAndPreservesLaterCadence() {
        var output: [(Int, Double)] = []
        let session = PlaybackSession {
            if $0.isDown, let index = $0.eventIndex { output.append((index, ProcessInfo.processInfo.systemUptime)) }
            return true
        }
        #expect(!session.skipWait())
        let plan = plan([
            PlannedEvent(kind: .character, value: "a", flight: 0, dwell: 20),
            PlannedEvent(kind: .character, value: "b", flight: 10_000, dwell: 20, pauseKind: .sentence),
            PlannedEvent(kind: .character, value: "c", flight: 160, dwell: 20)
        ])
        let start = ProcessInfo.processInfo.systemUptime
        var waits = 0
        let outcome = session.run(plan: plan, onProgress: {
            if $0.canSkipWait { waits += 1; #expect($0.pauseKind == .sentence); #expect(session.skipWait()) }
        })
        #expect(outcome == .complete)
        #expect(waits == 1)
        #expect(output.map(\.0) == [0, 1, 2])
        #expect(output[2].1 - output[1].1 >= 0.17)
        #expect(ProcessInfo.processInfo.systemUptime - start < 3)
        #expect(plan.events[1].flight == 10_000)
        #expect(!session.skipWait())
    }

    @Test func pausedTimeIsAddedToFutureDeadlines() {
        let paused = DispatchSemaphore(value: 0), finished = DispatchSemaphore(value: 0)
        var output: [Double] = []
        let session = PlaybackSession { if $0.isDown { output.append(ProcessInfo.processInfo.systemUptime) }; return true }
        let plan = plan([
            PlannedEvent(kind: .character, value: "a", flight: 0, dwell: 20),
            PlannedEvent(kind: .character, value: "b", flight: 180, dwell: 20)
        ])
        DispatchQueue.global().async {
            var didPause = false
            _ = session.run(plan: plan, onProgress: { progress in
                if !didPause && progress.fraction > 0 {
                    didPause = true; session.pause(); paused.signal()
                }
            })
            finished.signal()
        }
        #expect(paused.wait(timeout: .now() + 1) == .success)
        #expect(finished.wait(timeout: .now() + 0.25) == .timedOut)
        session.resume()
        #expect(finished.wait(timeout: .now() + 2) == .success)
        #expect(output.count == 2)
        #expect(output[1] - output[0] >= 0.44)
    }

    @Test func previewEditsPreserveUnicodeSelectionAndWordRepairs() {
        var buffer = PreviewTextBuffer()
        func event(_ kind: PlannedEventKind, _ value: String = "") -> PlannedEvent {
            PlannedEvent(kind: kind, value: value, flight: 0, dwell: 10)
        }
        buffer.apply(event(.character, "Hi 👩🏽‍💻 e\u{301}"))
        buffer.apply(event(.shiftArrowLeft))
        #expect(buffer.selectedRange == NSRange(location: "Hi 👩🏽‍💻 ".utf16.count, length: 2))
        buffer.apply(event(.character, "é"))
        #expect(buffer.text == "Hi 👩🏽‍💻 é")
        buffer.apply(event(.wordBackspace))
        #expect(buffer.text == "Hi 👩🏽‍💻 ")
        buffer.apply(event(.backspace))
        buffer.apply(event(.arrowLeft))
        buffer.apply(event(.character, "X"))
        buffer.apply(event(.arrowRight))
        buffer.apply(event(.enter))
        buffer.apply(event(.tab))
        #expect(buffer.text == "Hi X👩🏽‍💻\n\t")
    }

    @Test func previewMatchesGeneratedRepairsAcrossSeeds() {
        let source = "Their café receives definitely separate messages. 👩🏽‍💻\nBecause punctuation, omissions and corrections matter!"
        var settings = TypingSettings(); settings.mistakeLevel = 5; settings.sentencePauses = true
        var repairs = 0
        for seed in 1...100 {
            var random = SeededGenerator(seed: UInt64(seed))
            let plan = TypingEngine.generatePlan(text: source, settings: settings, profile: .baseline(), using: &random)
            var buffer = PreviewTextBuffer()
            for event in plan.events { buffer.apply(event) }
            repairs += plan.repairs
            #expect(Array(buffer.text.utf8) == Array(source.utf8), "Preview failed seed \(seed)")
        }
        #expect(repairs > 100)
    }

    @MainActor @Test func previewCanPauseSkipAndReplayWithoutStaleEdits() async throws {
        let preview = PlaybackPreviewController(plan: plan([
            PlannedEvent(kind: .character, value: "a", flight: 0, dwell: 20),
            PlannedEvent(kind: .character, value: "b", flight: 5_000, dwell: 20, pauseKind: .sentence)
        ]), text: "ab")
        preview.play()
        for _ in 0..<100 where !preview.progress.canSkipWait { try await Task.sleep(for: .milliseconds(10)) }
        #expect(preview.buffer.text == "a")
        preview.togglePause()
        try await Task.sleep(for: .milliseconds(100))
        #expect(preview.paused && preview.buffer.text == "a")
        preview.togglePause(); preview.skipWait()
        for _ in 0..<100 where preview.running { try await Task.sleep(for: .milliseconds(10)) }
        #expect(preview.buffer.text == "ab")
        #expect(preview.status == "Finished. Final text matches your source.")
        preview.play(); preview.stop(); preview.play()
        for _ in 0..<100 where !preview.progress.canSkipWait { try await Task.sleep(for: .milliseconds(10)) }
        preview.skipWait()
        for _ in 0..<100 where preview.running { try await Task.sleep(for: .milliseconds(10)) }
        #expect(preview.buffer.text == "ab")
        preview.stop()
    }
}
