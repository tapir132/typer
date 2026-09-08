import Foundation
import Testing
@testable import Typer

struct PlaybackCheckTests {
    private func perfect(_ scenario: PlaybackCheckScenario) -> [PlaybackReceipt] {
        let plan = scenario.fixture.plan
        return KeyTimeline.actions(for: KeyTimeline.strokes(for: plan.events)).map { action in
            let key = KeyDescriptor(event: plan.events[action.eventIndex])
            return PlaybackReceipt(eventIndex: action.eventIndex, isDown: action.isDown, code: key.code,
                                   shift: key.shift, option: key.option, eventOffset: action.offset, receiptOffset: action.offset)
        }
    }

    @Test(arguments: PlaybackCheckScenario.allCases)
    func perfectReceiptsMatchThePlan(scenario: PlaybackCheckScenario) throws {
        let report = PlaybackCheckReport.analyze(scenario: scenario, receipts: perfect(scenario), text: scenario.fixture.text, completed: true)
        #expect(report.integrityPassed)
        #expect(report.missingEvents == 0)
        #expect(report.plannedRollover == report.receivedRollover)
        #expect(report.timingErrors.allSatisfy { $0.median == 0 || $0.count == 0 })
        #expect(report.timingErrors.allSatisfy { $0.p95 == 0 || $0.count == 0 })
        let decoded = try JSONDecoder().decode(PlaybackCheckReport.self, from: JSONEncoder().encode(report))
        #expect(decoded.receipts == report.receipts)
    }

    @Test func missingDuplicateUnexpectedAndWrongModifierEventsAreVisible() {
        let scenario = PlaybackCheckScenario.rhythm
        var receipts = perfect(scenario)
        receipts.removeLast()
        receipts.append(receipts[0])
        var unexpected = receipts[1]
        unexpected.eventIndex = 50_000
        receipts.append(unexpected)
        receipts[0].option = true
        let report = PlaybackCheckReport.analyze(scenario: scenario, receipts: receipts, text: scenario.fixture.text, completed: true)
        #expect(!report.integrityPassed)
        #expect(report.missingEvents == 1)
        #expect(report.duplicateEvents == 1)
        #expect(report.unexpectedEvents == 1)
        #expect(report.modifierMismatches == 1)
    }

    @Test func correctEventTimestampsCannotHideAStalledReceiver() throws {
        let scenario = PlaybackCheckScenario.rhythm
        var receipts = perfect(scenario)
        // The queued events keep their original timestamps but arrive in a batch.
        for index in receipts.indices { receipts[index].receiptOffset = 5_000 }
        let report = PlaybackCheckReport.analyze(scenario: scenario, receipts: receipts, text: scenario.fixture.text, completed: true)
        #expect(report.integrityPassed) // Integrity and timing are distinct claims.
        #expect(report.receivedRollover == 0)
        #expect(try #require(report.plannedRollover) > 0)
        #expect(try #require(report.timingErrors.first { $0.name == "Key hold" }?.median) > 0)
        #expect(try #require(report.timingErrors.first { $0.name == "Arrival vs event timestamp" }?.p95) > 1_000)
    }

    @Test func outOfOrderAndIncompleteRunsNeverPass() {
        let scenario = PlaybackCheckScenario.rhythm
        var receipts = perfect(scenario)
        receipts.swapAt(0, 2)
        var report = PlaybackCheckReport.analyze(scenario: scenario, receipts: receipts, text: scenario.fixture.text, completed: true)
        #expect(report.outOfOrderEvents > 0 && !report.integrityPassed)
        report = PlaybackCheckReport.analyze(scenario: scenario, receipts: perfect(scenario), text: scenario.fixture.text, completed: false)
        #expect(!report.integrityPassed)
        report = PlaybackCheckReport.analyze(scenario: .unicode, receipts: perfect(.unicode),
                                             text: PlaybackCheckScenario.unicode.fixture.text.decomposedStringWithCanonicalMapping, completed: true)
        #expect(!report.textMatches)
    }

    @Test func nonfiniteReceiptsAreExcludedAndCanStillExport() throws {
        var receipts = perfect(.rhythm)
        receipts[0].receiptOffset = .nan
        let report = PlaybackCheckReport.analyze(scenario: .rhythm, receipts: receipts, text: "", completed: true)
        #expect(report.unexpectedEvents == 1 && report.missingEvents == 1)
        // A corrupt clock cannot silently appear as a zero-error run.
        #expect(!report.integrityPassed)
        _ = try JSONEncoder().encode(report)
    }

    @Test @MainActor func anotherWindowCannotReplaceOrReleaseAnActiveReceiver() {
        let router = PlaybackCheckRouter.shared
        let first = NSObject(), second = NSObject()
        defer { router.release(owner: first); router.release(owner: second) }
        #expect(router.acquire(owner: first, route: { _, _ in }, userInput: { _ in false }))
        #expect(!router.acquire(owner: second, route: { _, _ in }, userInput: { _ in false }))
        router.release(owner: second) // Closing an unrelated sheet cannot detach this run.
        #expect(!router.acquire(owner: second, route: { _, _ in }, userInput: { _ in false }))
        router.release(owner: first)
        #expect(router.acquire(owner: second, route: { _, _ in }, userInput: { _ in false }))
        router.release(owner: first) // A late close from the old sheet cannot detach the next run.
        #expect(!router.acquire(owner: first, route: { _, _ in }, userInput: { _ in false }))
    }
}
