import Testing
import AppKit
import Foundation
@testable import Typer

struct TypingEngineTests {
    @Test func plansAlwaysResolveToExactSource() {
        let inputs = [
            "The quick brown fox jumps over the lazy dog.",
            "Your update is definitely ready, and it's really good.",
            "First line.\nSecond line with\ta tab.",
            "Unicode survives — café, naïve, and 👋.\n    Indentation survives too.",
            "A longer sample because mistakes can appear in several different words and still resolve cleanly."
        ]
        for seed in 1...100 {
            for input in inputs {
                var random = TestGenerator(seed: UInt64(seed))
                var settings = TypingSettings()
                settings.wpm = 72
                settings.variation = 0.9
                settings.mistakeLevel = 5
                settings.delayedRepairs = true
                let plan = TypingEngine.generatePlan(text: input, settings: settings, profile: .baseline(wpm: 72), using: &random)
                #expect(apply(plan.events) == input, "Failed seed \(seed)")
                #expect(plan.events.allSatisfy { $0.flight >= 8 && $0.dwell >= 32 })
            }
        }
    }

    @Test func cleanModeProducesNoCorrections() {
        var random = TestGenerator(seed: 4)
        var settings = TypingSettings()
        settings.mistakeLevel = 0
        let plan = TypingEngine.generatePlan(text: "Clean typing only.", settings: settings, profile: .baseline(), using: &random)
        #expect(!plan.events.contains { $0.kind == .backspace })
        #expect(apply(plan.events) == "Clean typing only.")
    }

    @Test func trainingCapturesDwellFlightAndConfusion() {
        let records = [
            TrainingKeyRecord(id: UUID(), kind: .character, key: "t", expected: "t", pressTime: 0, dwell: 70, cursor: 0),
            TrainingKeyRecord(id: UUID(), kind: .character, key: "e", expected: "h", pressTime: 120, dwell: 82, cursor: 1),
            TrainingKeyRecord(id: UUID(), kind: .backspace, key: "Backspace", expected: "", pressTime: 420, cursor: 2, sinceMistake: 300),
            TrainingKeyRecord(id: UUID(), kind: .character, key: "h", expected: "h", pressTime: 500, dwell: 76, cursor: 1),
            TrainingKeyRecord(id: UUID(), kind: .character, key: "e", expected: "e", pressTime: 610, dwell: 73, cursor: 2)
        ]
        let sample = TypingEngine.summarize(records: records, target: "the", duration: 1_000)
        #expect(sample.repairDelay == 300)
        #expect(sample.confusions["h"] == ["e"])
        #expect(sample.dwellMedian > 0)
        #expect(sample.medianInterval - sample.dwellMedian > 0)
    }

    @Test func humanVariationDoesNotChangeMistakeChoices() {
        let text = "This longer paragraph contains enough ordinary words to produce several realistic corrections while timing changes independently."
        var lowSettings = TypingSettings()
        lowSettings.variation = 0
        lowSettings.mistakeLevel = 4
        var highSettings = lowSettings
        highSettings.variation = 1
        var lowRandom = TestGenerator(seed: 42)
        var highRandom = TestGenerator(seed: 42)
        let low = TypingEngine.generatePlan(text: text, settings: lowSettings, profile: .baseline(), using: &lowRandom)
        let high = TypingEngine.generatePlan(text: text, settings: highSettings, profile: .baseline(), using: &highRandom)
        #expect(low.repairs == high.repairs)
        #expect(low.duration != high.duration)
    }

    @Test func updaterPromptGateWaitsForIdleSession() {
        var gate = StartupUpdatePromptGate()
        gate.queue()
        let unavailable = gate.consumeIfReady(canCheck: false, sessionInProgress: false)
        let busy = gate.consumeIfReady(canCheck: true, sessionInProgress: true)
        let ready = gate.consumeIfReady(canCheck: true, sessionInProgress: false)
        let consumed = gate.consumeIfReady(canCheck: true, sessionInProgress: false)
        #expect(!unavailable)
        #expect(!busy)
        #expect(ready)
        #expect(!consumed)
    }

    @Test func updateChannelsMatchReleasePolicy() {
        #expect(UpdateChannel.stable.title == "Release")
        #expect(UpdateChannel.edge.title == "Edge")
    }

    @MainActor
    @Test func trainingEditorIsFocusableAndHasRealLayout() {
        let editor = TrainingEditorFactory.make(
            text: "",
            placeholder: "Type here",
            size: NSSize(width: 640, height: 220)
        )
        #expect(editor.isEditable)
        #expect(editor.isSelectable)
        #expect(editor.acceptsFirstResponder)
        #expect(editor.frame.width == 640)
        #expect(editor.frame.height == 220)
        #expect(editor.textContainer?.widthTracksTextView == true)
    }

    private func apply(_ events: [PlannedEvent]) -> String {
        var buffer: [Character] = []
        var cursor = 0
        for event in events {
            switch event.kind {
            case .character:
                for character in event.value { buffer.insert(character, at: cursor); cursor += 1 }
            case .enter: buffer.insert("\n", at: cursor); cursor += 1
            case .tab: buffer.insert("\t", at: cursor); cursor += 1
            case .backspace where cursor > 0: buffer.remove(at: cursor - 1); cursor -= 1
            case .arrowLeft: cursor = max(0, cursor - 1)
            case .arrowRight: cursor = min(buffer.count, cursor + 1)
            default: break
            }
        }
        return String(buffer)
    }
}

private struct TestGenerator: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
}
