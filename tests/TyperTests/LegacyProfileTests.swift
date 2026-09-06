import Foundation
import Testing
@testable import Typer

@MainActor
struct LegacyProfileTests {
    @Test func newTrainingNeverChangesTheLegacyProfile() throws {
        try withDefaults { defaults in
            let older = olderSample()
            let original = TypingEngine.merge(samples: Array(repeating: older, count: 4))
            try seed(defaults, profiles: [original], samples: Array(repeating: older, count: 4), active: original.id)
            let store = ProfileStore(defaults: defaults)
            let legacy = try #require(store.profiles.first)
            #expect(legacy.isLegacy && legacy.id == original.id)
            #expect(legacy.name == "Legacy rhythm")
            #expect(legacy.wpm == original.wpm && legacy.digraphs == original.digraphs)
            #expect(store.activeProfileID == original.id)

            #expect(store.add(sample: currentSample()))
            #expect(store.activeProfileID != legacy.id)
            #expect(store.activeProfile.name == "My rhythm" && !store.activeProfile.isLegacy)
            #expect(store.activeProfile.sampleCount == 1)
            let currentID = store.activeProfileID
            store.use(legacy)
            #expect(store.add(sample: currentSample(mode: .freewrite)))
            #expect(store.activeProfileID == currentID)
            #expect(store.activeProfile.sampleCount == 1)
            #expect(store.profiles.first { $0.id == legacy.id } == legacy)

            let reloaded = ProfileStore(defaults: defaults)
            #expect(reloaded.profiles.first { $0.id == legacy.id } == legacy)
        }
    }

    @Test func overwrittenLegacyProfileIsRecoveredOnceWithoutChangingCurrentSelection() throws {
        try withDefaults { defaults in
            let current = TypingEngine.merge(samples: [currentSample()])
            let samples = Array(repeating: olderSample(), count: 4) + [currentSample()]
            try seed(defaults, profiles: [current], samples: samples, active: current.id)
            let store = ProfileStore(defaults: defaults)
            let legacy = try #require(store.profiles.first(where: { $0.isLegacy }))
            #expect(legacy.sampleCount == 4 && legacy.evidence == nil)
            #expect(legacy.id != current.id)
            #expect(store.activeProfile == current)
            #expect(store.samples == samples)
            for _ in 0..<3 {
                let reloaded = ProfileStore(defaults: defaults)
                #expect(reloaded.profiles.filter { $0.isLegacy } == [legacy])
                #expect(reloaded.activeProfile == current)
            }
        }
    }

    @Test func oldFormatCannotBeAddedAsNewTraining() throws {
        try withDefaults { defaults in
            let store = ProfileStore(defaults: defaults)
            #expect(!store.add(sample: olderSample()))
            var missingMode = currentSample()
            missingMode.mode = nil
            #expect(!store.add(sample: missingMode))
            #expect(store.profiles.isEmpty && store.samples.isEmpty)
            #expect(store.activeProfileID == TypingProfile.baselineID)
        }
    }

    @Test func currentSampleLimitDoesNotRemoveLegacyArchive() throws {
        try withDefaults { defaults in
            let archive = Array(repeating: olderSample(), count: 4)
            try seed(defaults, profiles: [], samples: archive, active: TypingProfile.baselineID)
            let store = ProfileStore(defaults: defaults)
            let legacy = try #require(store.profiles.first(where: { $0.isLegacy }))
            for _ in 0..<18 { #expect(store.add(sample: currentSample())) }
            #expect(store.currentSampleCount == 12)
            #expect(store.legacySampleCount == 4)
            #expect(store.samples.filter { $0.isLegacy } == archive)
            #expect(store.profiles.first { $0.id == legacy.id } == legacy)
            #expect(store.activeProfile.sampleCount == 5)
        }
    }

    @Test(arguments: [true, false]) func deletingOneProfileKeepsTheOtherAndDoesNotResurrectIt(deleteLegacy: Bool) throws {
        try withDefaults { defaults in
            let current = TypingEngine.merge(samples: [currentSample()])
            try seed(defaults, profiles: [current], samples: Array(repeating: olderSample(), count: 4) + [currentSample()], active: current.id)
            let store = ProfileStore(defaults: defaults)
            let legacy = try #require(store.profiles.first(where: { $0.isLegacy }))
            store.remove(deleteLegacy ? legacy : current)
            let reloaded = ProfileStore(defaults: defaults)
            #expect(reloaded.profiles.count == 1)
            #expect(reloaded.profiles.first == (deleteLegacy ? current : legacy))
            #expect(reloaded.legacySampleCount == (deleteLegacy ? 0 : 4))
            #expect(reloaded.currentSampleCount == (deleteLegacy ? 1 : 0))
            if deleteLegacy { #expect(reloaded.activeProfile == current) }
            else { #expect(reloaded.activeProfileID == TypingProfile.baselineID) }
        }
    }

    private func withDefaults(_ body: (UserDefaults) throws -> Void) throws {
        let suite = "typer.legacy-tests.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        try body(defaults)
    }

    private func seed(_ defaults: UserDefaults, profiles: [TypingProfile], samples: [TrainingSample], active: UUID) throws {
        defaults.set(try JSONEncoder().encode(profiles), forKey: "typer.profiles.v1")
        defaults.set(try JSONEncoder().encode(samples), forKey: "typer.samples.v1")
        defaults.set(active.uuidString, forKey: "typer.activeProfile.v1")
    }

    private func currentSample(mode: TrainingMode = .copy) -> TrainingSample {
        let text = String(repeating: "the quick brown fox ", count: 3)
        let records = text.enumerated().map { index, character in
            TrainingKeyRecord(id: UUID(), kind: .character, key: String(character), expected: String(character),
                              pressTime: Double(index) * 110, dwell: 95, cursor: index)
        }
        return TypingEngine.summarize(records: records, target: text, duration: Double(text.count) * 110, mode: mode)
    }

    private func olderSample() -> TrainingSample {
        var sample = currentSample()
        sample.evidence = nil; sample.mode = nil; sample.capturedAt = nil; sample.referenceText = nil
        return sample
    }
}
