import Foundation
import Testing
@testable import Typer

struct PlaybackCheckpointTests {
    @Test func aRestoredRunCanBeSavedAgainBeforeItsWorkerStarts() {
        let checkpoint = PlaybackCheckpoint(nextAction: 8, elapsed: 42.5, rewindOwner: 3)
        let session = PlaybackSession { _ in true }
        session.prepare(checkpoint: checkpoint)
        session.pause()
        #expect(session.checkpoint() == checkpoint)
        session.cancel()
    }
    private func plan() -> TypingPlan {
        let normalized = KeyTimeline.normalized([
            PlannedEvent(kind: .character, value: "a", flight: 10, dwell: 100),
            PlannedEvent(kind: .character, value: "b", flight: -50, dwell: 100),
            PlannedEvent(kind: .shiftArrowLeft, flight: 80, dwell: 50),
            PlannedEvent(kind: .character, value: "X", flight: 80, dwell: 70),
            PlannedEvent(kind: .character, value: "é", flight: 80, dwell: 80),
            PlannedEvent(kind: .arrowLeft, flight: 80, dwell: 50),
            PlannedEvent(kind: .character, value: "!", flight: 80, dwell: 70),
            PlannedEvent(kind: .arrowRight, flight: 80, dwell: 50),
            PlannedEvent(kind: .enter, flight: 80, dwell: 50),
            PlannedEvent(kind: .character, value: "🙂", flight: 80, dwell: 70),
            PlannedEvent(kind: .character, value: "z", flight: 300_000, dwell: 20, pauseKind: .paragraph)
        ])
        return TypingPlan(events: normalized.events, duration: normalized.duration, repairs: 1, effectiveWPM: 0)
    }

    @Test func aNewSessionRestoresHeldKeysSelectionsNavigationAccentsAndWaits() throws {
        let plan = plan()
        let actions = KeyTimeline.physicalActions(for: plan.events)
        let selected = [0, 2, 5].map { event in actions.firstIndex { $0.isDown && $0.eventIndex == event }! }
        let accent = try #require(actions.firstIndex { $0.isCompositionPrefix && $0.isDown })
        for split in selected + [accent] {
            var buffer = PreviewTextBuffer(), held = Set<UInt16>(), delivered: [Int] = []
            func receive(_ action: PhysicalKeyAction) -> Bool {
                if action.isDown { held.insert(action.code) } else { held.remove(action.code) }
                if action.isDown, let index = action.eventIndex { buffer.apply(plan.events[index]); delivered.append(index) }
                return true
            }
            let original = PlaybackSession(emit: receive)
            var checkpoint: PlaybackCheckpoint?
            let outcome = original.run(plan: plan, onProgress: { progress in
                if checkpoint == nil && progress.fraction >= Double(split + 1) / Double(actions.count) {
                    original.pause(); checkpoint = original.checkpoint(); original.cancel()
                }
            })
            #expect(outcome == .cancelled && held.isEmpty)
            let saved = try #require(checkpoint)
            if split == accent { #expect(saved.rewindOwner == 4) }
            // Simulate the process boundary: nothing from the old session is
            // available except its encoded cursor and the document's edits.
            let decoded = try JSONDecoder().decode(PlaybackCheckpoint.self, from: JSONEncoder().encode(saved))
            let restored = PlaybackSession(emit: receive)
            let resumed = restored.run(plan: plan, checkpoint: decoded, onProgress: { progress in
                if progress.canSkipWait { #expect(restored.skipWait()) }
            })
            #expect(resumed == .complete && held.isEmpty)
            #expect(buffer.text == "aX!é\n🙂z")
            #expect(delivered == Array(plan.events.indices), "A logical key was repeated or skipped at action \(split)")
        }
    }

    @Test func savingDuringParagraphWaitKeepsTheRemainingWaitAcrossAnOvernightGap() throws {
        let plan = plan()
        let session = PlaybackSession { _ in true }
        var snapshot: PlaybackCheckpoint?, remaining = 0.0
        _ = session.run(plan: plan, onProgress: { progress in
            if progress.pauseKind == .paragraph && snapshot == nil {
                session.pause(); snapshot = session.checkpoint(); remaining = progress.waitRemaining; session.cancel()
            }
        })
        let checkpoint = try #require(snapshot)
        let restored = PlaybackSession { _ in true }
        var firstWait: Double?
        let result = restored.run(plan: plan, checkpoint: checkpoint, onProgress: { progress in
            if progress.pauseKind == .paragraph && firstWait == nil {
                firstWait = progress.waitRemaining
                #expect(restored.skipWait())
            }
        })
        #expect(result == .complete)
        #expect(abs(try #require(firstWait) - remaining) < 0.1)
        #expect(remaining > 299)
    }

    @Test func malformedCheckpointsCannotSendAnyKey() {
        let plan = plan()
        for checkpoint in [PlaybackCheckpoint(nextAction: -1, elapsed: 0),
                           PlaybackCheckpoint(nextAction: Int.max, elapsed: 0),
                           PlaybackCheckpoint(nextAction: 0, elapsed: .infinity),
                           PlaybackCheckpoint(nextAction: 0, elapsed: -1),
                           PlaybackCheckpoint(nextAction: 0, elapsed: 0, rewindOwner: Int.max)] {
            var sent = 0
            let session = PlaybackSession { _ in sent += 1; return true }
            #expect(session.run(plan: plan, checkpoint: checkpoint) == .failed)
            #expect(sent == 0)
        }
    }
}
