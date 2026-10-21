import AppKit
import Testing
@testable import Typer

@MainActor
@Suite(.serialized)
struct ResumeSessionTests {
    @Test func stoppedRunKeepsItsClockAndPlanThroughResetRepeatedStopAndCountdownCancel() async throws {
        _ = NSApplication.shared
        let suite = "typer.resume.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let shortcuts = ShortcutManager(defaults: defaults, driver: TestShortcutDriver())
        let controller = TypingController(shortcuts: shortcuts)
        controller.overlayEnabled = false
        let normalized = KeyTimeline.normalized([
            PlannedEvent(kind: .character, value: "a", flight: 0, dwell: 20),
            PlannedEvent(kind: .backspace, flight: 300_000, dwell: 20, pauseKind: .paragraph),
            PlannedEvent(kind: .character, value: "b", flight: 30, dwell: 20)
        ])
        let plan = TypingPlan(events: normalized.events, duration: normalized.duration, repairs: 1, effectiveWPM: 0)
        let first = DispatchSemaphore(value: 0), last = DispatchSemaphore(value: 0)
        let session = PlaybackSession { action in
            if action.isDown && action.eventIndex == 0 { first.signal() }
            if action.isDown && action.eventIndex == 2 { last.signal() }
            return true
        }
        defer { controller.discardSession() }
        controller.run(plan: plan, session: session, target: .current, field: nil)
        try #require(try await playbackSignal(first))
        for _ in 0..<100 where !controller.progress.canSkipWait { try await Task.sleep(for: .milliseconds(10)) }
        controller.stop()
        #expect(controller.state == .stopped && controller.canResume)
        #expect(controller.progress.isPaused && controller.lastPlan == plan)
        let remaining = controller.progress.remaining
        controller.reset(); controller.stop()
        #expect(controller.state == .stopped && controller.canResume)
        controller.resumeStopped()
        #expect(controller.state == .armed(5))
        controller.stop()
        #expect(controller.state == .stopped && controller.canResume)
        try await Task.sleep(for: .milliseconds(120))
        #expect(controller.progress.remaining == remaining, "Queued progress must not change the stopped timer")
        #expect(!takePlaybackSignal(last))
        // Resume this same retained scheduler with a mock transport. Production
        // performs app/field focus checks before this point.
        session.resume()
        for _ in 0..<100 where !session.skipWait() { try await Task.sleep(for: .milliseconds(10)) }
        try #require(try await playbackSignal(last))
        for _ in 0..<100 where controller.state != .complete { try await Task.sleep(for: .milliseconds(10)) }
        #expect(controller.state == .complete && !controller.canResume)
        #expect(!takePlaybackSignal(first), "Resume repeated the first character")
    }

    @Test func startingOverDiscardsTheOldPausedSchedulerWithoutSendingMoreText() async throws {
        _ = NSApplication.shared
        let suite = "typer.resume.discard.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let controller = TypingController(shortcuts: ShortcutManager(defaults: defaults, driver: TestShortcutDriver()))
        controller.overlayEnabled = false
        let sent = DispatchSemaphore(value: 0)
        let session = PlaybackSession { action in if action.isDown { sent.signal() }; return true }
        let plan = TypingPlan(events: [PlannedEvent(kind: .character, value: "x", flight: 300_000, dwell: 20)],
                              duration: 300_020, repairs: 0, effectiveWPM: 0)
        controller.run(plan: plan, session: session, target: .current, field: nil)
        controller.pause(); controller.stop()
        #expect(controller.canResume)
        controller.discardSession()
        #expect(!controller.canResume && controller.progress == PlaybackProgress())
        session.resume(); _ = session.skipWait()
        try await Task.sleep(for: .milliseconds(120))
        #expect(!takePlaybackSignal(sent))
        controller.reset(); #expect(controller.state == .ready)
    }
}
