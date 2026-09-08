import Foundation
import Testing
@testable import Typer

struct PauseLearningTests {
    private func records(_ text: String, intervals: [Int: Double] = [:]) -> [TrainingKeyRecord] {
        var time = 0.0
        return text.enumerated().map { index, character in
            time += intervals[index] ?? 150
            return TrainingKeyRecord(id: UUID(), kind: .character, key: String(character), expected: "",
                                     pressTime: time, dwell: 80, cursor: index)
        }
    }

    @Test func sentenceBoundaryUsesOneLongestIdleAcrossPunctuationQuotesAndSpaces() throws {
        let observations = PauseLearning.extract(records("Go?!\"  Next.", intervals: [3: 1_580, 4: 2_080, 6: 3_080]))
        let sentence = try #require(observations[PauseContext.sentence.rawValue])
        #expect(sentence.opportunities == 1 && sentence.pauseCount == 1)
        #expect(sentence.durations == [3_000])
        #expect(observations[PauseContext.word.rawValue] == nil)
        #expect(observations[PauseContext.withinWord.rawValue]?.opportunities == 4)
        #expect(PauseLearning.extract(records("One.  "))[PauseContext.sentence.rawValue] == nil)
    }

    @Test func contextsDistinguishWordsAndExcludeDecimalsEditsAndInvalidGaps() {
        let word = PauseLearning.extract(records("ab cd", intervals: [1: 1_580, 3: 2_580]))
        #expect(word[PauseContext.withinWord.rawValue]?.durations == [1_500])
        #expect(word[PauseContext.word.rawValue]?.durations == [2_500])
        #expect(PauseLearning.extract(records("3.14"))[PauseContext.sentence.rawValue] == nil)
        for invalid in [Double.infinity, Double.nan, -10, 70_000] {
            var input = records("a. b")
            input[2].pressTime = invalid
            #expect(PauseLearning.extract(input)[PauseContext.sentence.rawValue] == nil)
        }
        var input = records("a. b")
        input[2].kind = .navigation
        #expect(PauseLearning.extract(input)[PauseContext.sentence.rawValue] == nil)
        input = records("a. b"); input[1].dwell = nil
        #expect(PauseLearning.extract(input)[PauseContext.sentence.rawValue] == nil)
    }

    @Test func supportRequiresRepeatedSessionsAndUsesBoundedTimingOnly() throws {
        let one = PauseDistribution(opportunities: 100, pauseCount: 10, durations: Array(repeating: 5_000, count: 10))
        #expect(!one.isSupported)
        let merged = try #require(PauseLearning.merge(Array(repeating: ["sentence": one], count: 5))["sentence"])
        #expect(merged.sessions == 5 && merged.isSupported)
        #expect(merged.weight < 1)
        #expect(PauseLearning.draw(one, baselineFrequency: 0, decision: 0, selection: 0, length: 0) == nil)
        #expect(PauseLearning.draw(merged, baselineFrequency: 0, decision: 0, selection: 0, length: 0)! < 5_000)
        #expect(PauseLearning.draw(merged, baselineFrequency: 0, decision: 0.99, selection: 0, length: 0) == nil)
        let huge = PauseDistribution(opportunities: 100_000, pauseCount: 50_000,
                                     durations: Array(repeating: 2_000, count: 1_000) + [.nan, -1, 90_000])
        let bounded = try #require(PauseLearning.merge(Array(repeating: ["word": huge], count: 5))["word"])
        #expect(bounded.opportunities == 512 * 5 && bounded.pauseCount == 256 * 5)
        #expect(bounded.durations.count <= 128 && bounded.durations.allSatisfy { $0 == 2_000 })
        let encoded = try JSONEncoder().encode(PauseLearning.extract(records("private words. Next.", intervals: [14: 2_080])))
        let json = String(decoding: encoded, as: UTF8.self)
        #expect(!json.contains("private") && !json.contains("Next") && !json.contains("pressTime"))
    }

    @Test func olderEvidenceAndProfilesDecodeWithoutPauseContexts() throws {
        var original = TypingProfile.baseline(); original.id = UUID(); original.sampleCount = 2
        original.evidence = TimingEvidence()
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(TypingProfile.self, from: data)
        #expect(!decoded.isLegacy && decoded.trainingMode == nil && decoded.evidence?.pauseContexts == nil)
        let event = try JSONDecoder().decode(PlannedEvent.self, from: Data(#"{"kind":"character","value":"a","flight":10,"dwell":80}"#.utf8))
        #expect(event.pauseKind == nil)
    }

    @Test func pauseValidationDistinguishesMissingEvidenceFromZeroObservedPauses() throws {
        let older = TimingEvidence()
        var human = TimingEvidence(), generated = TimingEvidence()
        human.pauseContexts = ["word": PauseDistribution(opportunities: 20, pauseCount: 0)]
        generated.pauseContexts = ["word": PauseDistribution(opportunities: 40, pauseCount: 10, durations: [2_000, 3_000])]
        let comparison = TypingValidation.compare(reference: human, candidate: generated)
        let word = try #require(comparison.pauseRates?.first { $0.name == PauseContext.word.label })
        #expect(word.referenceFrequency == 0 && word.candidateFrequency == 0.25)
        #expect(word.referenceOpportunities == 20 && word.candidateOpportunities == 40)
        let old = TypingValidation.compare(reference: older, candidate: generated)
        #expect(old.pauseRates?.allSatisfy { $0.referenceFrequency == nil } == true)
        #expect(comparison.distributions.first { $0.name == "Pause: Word boundaries" }?.wassersteinDistance == nil)
        #expect(try JSONDecoder().decode(TraceComparison.self, from: JSONEncoder().encode(comparison)) == comparison)
    }

    @Test func learnedPausesRequireKnownContextAndRespectToggleWithoutChangingRepairs() {
        var profile = TypingProfile.baseline(); profile.id = UUID(); profile.sampleCount = 5; profile.trainingMode = .copy
        var evidence = TimingEvidence()
        evidence.pauseContexts = ["word": PauseDistribution(opportunities: 200, pauseCount: 200,
            durations: Array(repeating: 6_000, count: 30), sessions: 5)]
        profile.evidence = evidence
        var settings = TypingSettings(); settings.mode = .personal; settings.thoughtPauses = false; settings.mistakeLevel = 5
        let text = String(repeating: "Their separate messages receive replies. ", count: 20)
        func generate(_ profile: TypingProfile, _ settings: TypingSettings) -> TypingPlan {
            var random = SeededGenerator(seed: 48)
            return TypingEngine.generatePlan(text: text, settings: settings, profile: profile, using: &random)
        }
        let learned = generate(profile, settings)
        #expect(learned.events.filter { $0.pauseKind == .learned }.count > 10)
        settings.learnedPauses = false
        let fallback = generate(profile, settings)
        #expect(fallback.events.allSatisfy { $0.pauseKind != .learned })
        #expect(learned.events.map(\.kind) == fallback.events.map(\.kind))
        #expect(learned.events.map(\.value) == fallback.events.map(\.value))
        settings.learnedPauses = true; profile.trainingMode = nil
        #expect(generate(profile, settings) == fallback)
        let copy = TypingEngine.summarize(records: records("Copy words."), target: "", duration: 2_000, mode: .copy)
        var freewrite = copy; freewrite.mode = .freewrite
        #expect(TypingEngine.merge(samples: [copy, copy]).trainingMode == .copy)
        #expect(TypingEngine.merge(samples: [copy, freewrite]).trainingMode == nil)
    }

    @MainActor @Test func settingsAndPresetsPersistWithoutSourceOrChangingBuiltIns() throws {
        let suite = "typer.settings-test.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = SettingsStore(defaults: defaults)
        var settings = TypingSettings(); settings.showTypingOverlay = false; settings.sentencePauses = true; settings.wpm = 82
        store.save(settings)
        let preset = try #require(store.add(name: "  My daily writing  ", settings: settings))
        #expect(preset.name == "My daily writing")
        #expect(store.add(name: "my DAILY writing", settings: settings) == nil)
        #expect(store.add(name: "Clean copy", settings: settings) == nil)
        #expect(store.add(name: "  ", settings: settings) == nil)
        let reloaded = SettingsStore(defaults: defaults)
        #expect(reloaded.settings == settings && reloaded.presets.last == preset)
        reloaded.remove(TypingPreset.defaults[0].id)
        #expect(reloaded.presets.count == 4)
        reloaded.remove(preset.id)
        #expect(SettingsStore(defaults: defaults).presets == TypingPreset.defaults)
        settings.wpm = .nan; settings.variation = .infinity; settings.mistakeLevel = Int.max
        settings.sentencePauseMinimum = Int.max; settings.sentencePauseMaximum = Int.min
        store.save(settings)
        #expect(store.settings.wpm == 64 && store.settings.variation.isFinite && store.settings.mistakeLevel == 5)
        #expect(store.settings.sentencePauseSeconds == 1...60)
        #expect(Set(defaults.persistentDomain(forName: suite)!.keys) == ["typer.settings.v1", "typer.presets.v1"])
        for index in 0..<30 { #expect(reloaded.add(name: "Setup \(index)", settings: settings) != nil) }
        #expect(reloaded.add(name: "Over limit", settings: settings) == nil)
    }
}
