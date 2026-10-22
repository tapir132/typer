import AppKit
import Foundation
import Testing
@testable import Typer

@MainActor
@Suite(.serialized)
struct SavedRunTests {
    private func fixture() -> SavedTypingRun {
        let normalized = KeyTimeline.normalized([
            PlannedEvent(kind: .character, value: "a", flight: 10, dwell: 20),
            PlannedEvent(kind: .character, value: "b", flight: 300_000, dwell: 20, pauseKind: .paragraph)
        ])
        let plan = TypingPlan(events: normalized.events, duration: normalized.duration, repairs: 0, effectiveWPM: 0)
        var settings = TypingSettings(); settings.wpm = 92; settings.paragraphPauses = true
        return SavedTypingRun(context: TypingRunContext(text: "ab", settings: settings), plan: plan,
            checkpoint: PlaybackCheckpoint(nextAction: 2, elapsed: 0.03), layoutIdentifier: KeyboardLayout.us.identifier,
            actions: KeyTimeline.physicalActions(for: plan.events), targetBundleIdentifier: "com.example.Editor", targetName: "Test editor")
    }

    private func temporaryURL() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("typer-saved-run-tests-\(UUID())/private/current.json")
    }

    @Test func atomicSaveRoundTripsIntoANewStoreWithPrivatePermissions() throws {
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent().deletingLastPathComponent()) }
        let store = SavedRunStore(url: url), original = fixture()
        try store.save(original)
        #expect(try SavedRunStore(url: url).load() == original)
        let permissions = try #require(FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber)
        let parent = try #require(FileManager.default.attributesOfItem(atPath: url.deletingLastPathComponent().path)[.posixPermissions] as? NSNumber)
        #expect(permissions.intValue & 0o777 == 0o600 && parent.intValue & 0o777 == 0o700)
        var replacement = original; replacement.savedAt = Date(timeIntervalSince1970: 1_700_000_000)
        try store.save(replacement)
        #expect(try SavedRunStore(url: url).load() == replacement)
        let contents = try FileManager.default.contentsOfDirectory(atPath: url.deletingLastPathComponent().path)
        #expect(contents == ["current.json"])
        try store.remove()
        #expect(try SavedRunStore(url: url).load() == nil)
    }

    @Test func malformedOrFutureFilesAreKeptAndBadWritesDoNotReplaceAValidRun() throws {
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent().deletingLastPathComponent()) }
        let store = SavedRunStore(url: url), valid = fixture()
        try store.save(valid)
        var invalid = valid; invalid.checkpoint.nextAction = Int.max
        #expect(throws: (any Error).self) { try store.save(invalid) }
        #expect(try store.load() == valid)
        var json = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        json["version"] = 99
        let unsupported = try JSONSerialization.data(withJSONObject: json)
        try unsupported.write(to: url)
        #expect(throws: (any Error).self) { try store.load() }
        #expect(try Data(contentsOf: url) == unsupported)
        try Data("not json".utf8).write(to: url)
        #expect(throws: (any Error).self) { try store.load() }
        #expect(FileManager.default.fileExists(atPath: url.path))
    }

    @Test func layoutAndPhysicalScheduleMustMatchBeforeRestoration() {
        let saved = fixture()
        #expect(saved.isCompatible(with: .us))
        var changed = saved; changed.actions[0].code = 99
        #expect(!changed.isCompatible(with: .us))
        changed = saved; changed.layoutIdentifier = "a different layout"
        #expect(!changed.isCompatible(with: .us))
        #expect(saved.typedBuffer.text == "a" && saved.cursorHint.contains("a│"))
        #expect(saved.progress.remaining > 299 && saved.progress.isPaused)
    }

    @Test func savingAndReopeningRestoresTextSettingsPositionWithoutTyping() async throws {
        _ = NSApplication.shared
        let url = temporaryURL(), suite = "typer.saved-lifecycle.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: url.deletingLastPathComponent().deletingLastPathComponent())
        }
        let store = SavedRunStore(url: url), saved = fixture()
        let controller = TypingController(shortcuts: ShortcutManager(defaults: defaults, driver: TestShortcutDriver()), savedRuns: store)
        controller.overlayEnabled = false
        let first = DispatchSemaphore(value: 0), last = DispatchSemaphore(value: 0)
        let session = PlaybackSession { action in
            if action.isDown && action.eventIndex == 0 { first.signal() }
            if action.isDown && action.eventIndex == 1 { last.signal() }
            return true
        }
        controller.run(plan: saved.plan, session: session, target: .current, field: nil, context: saved.context)
        try #require(try await playbackSignal(first))
        #expect(await controller.saveForLater())
        #expect(controller.state == .stopped && controller.canResume && controller.savedRun != nil)
        #expect(await controller.prepareForQuit())
        let reopened = AppModel(profileStore: ProfileStore(defaults: defaults),
            shortcuts: ShortcutManager(defaults: defaults, driver: TestShortcutDriver()), savedRuns: SavedRunStore(url: url))
        reopened.controller.overlayEnabled = false
        #expect(reopened.sourceText == "ab" && reopened.settings.wpm == 92)
        #expect(reopened.controller.state == .stopped && reopened.controller.canResume)
        #expect(reopened.controller.savedRun?.checkpoint.nextAction ?? 0 > 0)
        try await Task.sleep(for: .milliseconds(100))
        #expect(!takePlaybackSignal(last))
        reopened.controller.resumeStopped()
        #expect(reopened.controller.state == .armed(5))
        reopened.controller.stop()
        #expect(reopened.controller.state == .stopped && store.hasStoredRun)
        #expect(await reopened.controller.prepareForQuit())
        #expect(try store.load() != nil)
        #expect(reopened.controller.discardSession())
        #expect(try store.load() == nil)
    }

    @Test func savingThenImmediatelyQuittingWaitsForTheRequestedWrite() async throws {
        _ = NSApplication.shared
        let url = temporaryURL(), suite = "typer.saved-immediate-quit.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: url.deletingLastPathComponent().deletingLastPathComponent())
        }
        let saved = fixture(), store = SavedRunStore(url: url)
        let controller = TypingController(shortcuts: ShortcutManager(defaults: defaults, driver: TestShortcutDriver()), savedRuns: store)
        controller.overlayEnabled = false
        controller.run(plan: saved.plan, session: PlaybackSession { _ in true }, target: .current,
                       field: nil, context: saved.context, checkpoint: saved.checkpoint)
        controller.requestSaveForLater()
        #expect(controller.isSavingForLater && controller.state == .paused)
        #expect(await controller.prepareForQuit())
        let restored = try #require(try store.load())
        #expect(restored.checkpoint.nextAction == saved.checkpoint.nextAction)
        #expect(restored.context == saved.context && controller.savedRun == restored)
        #expect(!controller.isSavingForLater)
    }

    @Test func aSaveCannotResumeOrReappearAfterStartingOver() async throws {
        _ = NSApplication.shared
        let store = SavedRunStore(url: nil), saved = fixture()
        let suite = "typer.saved-cancel.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let controller = TypingController(shortcuts: ShortcutManager(defaults: defaults, driver: TestShortcutDriver()), savedRuns: store)
        controller.overlayEnabled = false
        let session = PlaybackSession { _ in true }
        controller.run(plan: saved.plan, session: session, target: .current, field: nil, context: saved.context)
        let save = Task { await controller.saveForLater() }
        for _ in 0..<100 where !controller.isSavingForLater { try await Task.sleep(for: .milliseconds(5)) }
        #expect(controller.state == .paused && controller.isSavingForLater)
        controller.togglePause()
        #expect(controller.state == .paused)
        controller.discardSession()
        #expect(!(await save.value))
        try await Task.sleep(for: .milliseconds(250))
        #expect(try store.load() == nil && !controller.canResume)
    }

    @Test func aFailedSaveKeepsTheRunPausedAndPreventsLosingItOnQuit() async throws {
        _ = NSApplication.shared
        let badParent = FileManager.default.temporaryDirectory.appendingPathComponent("typer-save-failure-\(UUID())")
        try Data("a file, not a directory".utf8).write(to: badParent)
        defer { try? FileManager.default.removeItem(at: badParent) }
        let suite = "typer.saved-failure.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let controller = TypingController(shortcuts: ShortcutManager(defaults: defaults, driver: TestShortcutDriver()),
            savedRuns: SavedRunStore(url: badParent.appendingPathComponent("current.json")))
        controller.overlayEnabled = false
        let saved = fixture(), session = PlaybackSession { _ in true }
        controller.run(plan: saved.plan, session: session, target: .current, field: nil, context: saved.context)
        #expect(!(await controller.saveForLater()))
        #expect(controller.state == .paused && controller.canResume && controller.savedRunError != nil)
        #expect(!(await controller.prepareForQuit()))
        session.cancel()
    }

    @Test func normalQuitUpdatesAResumedRunEvenWithNoWindowOpen() async throws {
        _ = NSApplication.shared
        let url = temporaryURL(), suite = "typer.saved-quit.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: url.deletingLastPathComponent().deletingLastPathComponent())
        }
        let saved = fixture(), store = SavedRunStore(url: url)
        try store.save(saved)
        let model = AppModel(profileStore: ProfileStore(defaults: defaults),
            shortcuts: ShortcutManager(defaults: defaults, driver: TestShortcutDriver()), savedRuns: store)
        model.controller.overlayEnabled = false
        let repeated = DispatchSemaphore(value: 0)
        let session = PlaybackSession { action in
            if action.isDown && action.eventIndex == 0 { repeated.signal() }
            return true
        }
        model.controller.run(plan: saved.plan, session: session, target: .current, field: nil,
                             context: saved.context, checkpoint: saved.checkpoint)
        try await Task.sleep(for: .milliseconds(100))
        let request = TyperQuitRequest()
        NotificationCenter.default.post(name: .typerWillQuit, object: request)
        #expect(!request.prepare.isEmpty)
        for prepare in request.prepare { #expect(await prepare()) }
        let updated = try #require(try store.load())
        #expect(updated.checkpoint.nextAction == saved.checkpoint.nextAction)
        #expect(updated.checkpoint.elapsed >= saved.checkpoint.elapsed)
        #expect(updated.id != saved.id, "Normal Quit must write a fresh checkpoint")
        #expect(!takePlaybackSignal(repeated))
        #expect(model.controller.state == .stopped && store.hasStoredRun)
    }

    @Test func midSelectionRestoresTheAnchorAndReplaysOnlyNonTextSelectionKeys() throws {
        let events = "bad".map { PlannedEvent(kind: .character, value: String($0), flight: 20, dwell: 20) }
            + (0..<3).map { _ in PlannedEvent(kind: .shiftArrowLeft, flight: 20, dwell: 20) }
            + "good".map { PlannedEvent(kind: .character, value: String($0), flight: 20, dwell: 20) }
        let normalized = KeyTimeline.normalized(events)
        let plan = TypingPlan(events: normalized.events, duration: normalized.duration, repairs: 1, effectiveWPM: 0)
        let actions = KeyTimeline.physicalActions(for: plan.events)
        let down = try #require(actions.firstIndex { $0.isDown && $0.eventIndex == 3 })
        let saved = SavedTypingRun(context: TypingRunContext(text: "good", settings: TypingSettings()), plan: plan,
            checkpoint: PlaybackCheckpoint(nextAction: down + 1, elapsed: (actions[down].scheduledOffset ?? 0) / 1_000 + 0.001),
            layoutIdentifier: KeyboardLayout.us.identifier, actions: actions, targetBundleIdentifier: "com.example.Editor", targetName: "Test editor",
            field: SavedFieldState(documentDigest: SavedFieldState.digest("bad"), selection: NSRange(location: 2, length: 1)))
        try saved.validate()
        #expect(saved.resumeField?.selection == NSRange(location: 3, length: 0))
        #expect(saved.resumeCheckpoint.nextAction < saved.checkpoint.nextAction)
        var buffer = saved.typedBuffer
        buffer.apply(PlannedEvent(kind: .arrowRight, flight: 0, dwell: 20)) // restored anchor
        var characters = ""
        let session = PlaybackSession { action in
            if action.isDown, let index = action.eventIndex {
                buffer.apply(plan.events[index])
                if plan.events[index].kind == .character { characters += plan.events[index].value }
            }
            return true
        }
        #expect(session.run(plan: plan, checkpoint: saved.resumeCheckpoint) == .complete)
        #expect(buffer.text == "good" && characters == "good")
    }

    @Test func startingANewRunCannotSilentlyDeleteAnUnreadableSavedFile() throws {
        _ = NSApplication.shared
        let url = temporaryURL(), suite = "typer.saved-recovery.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: url.deletingLastPathComponent().deletingLastPathComponent())
        }
        let store = SavedRunStore(url: url)
        try store.save(fixture())
        let unreadable = Data("future format, kept until explicitly discarded".utf8)
        try unreadable.write(to: url)
        let model = AppModel(profileStore: ProfileStore(defaults: defaults),
            shortcuts: ShortcutManager(defaults: defaults, driver: TestShortcutDriver()), savedRuns: store)
        #expect(model.controller.needsSavedRunRecovery)
        model.arm()
        #expect(try Data(contentsOf: url) == unreadable)
        #expect(model.controller.discardSession())
        #expect(!store.hasStoredRun && !model.controller.needsSavedRunRecovery)
    }
}
