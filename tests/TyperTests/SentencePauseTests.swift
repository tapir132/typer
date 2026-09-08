import Foundation
import Testing
@testable import Typer

struct SentencePauseTests {
    private func settings(minimum: Int = 2, maximum: Int = 10) -> TypingSettings {
        var settings = TypingSettings()
        settings.mode = .clean
        settings.thoughtPauses = false
        settings.fatigueDrift = false
        settings.sentencePauses = true
        settings.sentencePauseMinimum = minimum
        settings.sentencePauseMaximum = maximum
        return settings
    }

    private func plan(_ text: String, settings: TypingSettings, seed: UInt64 = 42) -> TypingPlan {
        var random = SeededGenerator(seed: seed)
        return TypingEngine.generatePlan(text: text, settings: settings, profile: .baseline(), using: &random)
    }

    @Test func pausesOnceAfterCompleteSentencesAndClosingQuotes() {
        let fixtures: [(String, [String])] = [
            ("One. Two! Three?", ["One.", "One. Two!"]),
            ("Wait... Really?! Yes.", ["Wait...", "Wait... Really?!"]),
            ("She said, “Go.” Next up!", ["She said, “Go.”"]),
            ("Dr. Smith paid 3.14 dollars. Then left.", ["Dr. Smith paid 3.14 dollars."]),
            ("Email a@b.com. Then visit example.com today.", ["Email a@b.com."]),
            ("One.\n\nTwo.\n", ["One."]),
            ("你好。再见！Done.", ["你好。", "你好。再见！"]),
            ("Just one sentence. \n", []),
            ("An unfinished thought\nAnother line", [])
        ]
        for (text, expectedPrefixes) in fixtures {
            let plan = plan(text, settings: settings(minimum: 10, maximum: 10))
            let characters = Array(text)
            let prefixes = plan.events.enumerated().compactMap { index, event in
                event.flight > 9_999 ? String(characters.prefix(index)) : nil
            }
            #expect(prefixes == expectedPrefixes, "Wrong sentence boundaries for \(text.debugDescription)")
            #expect(plan.events.map(\.value).joined() == text)
            #expect(plan.duration == KeyTimeline.strokes(for: plan.events).map(\.releaseOffset).max())
        }
    }

    @Test func defaultRangeIsRandomAndCanExceedTheOrdinaryEightSecondCap() {
        let text = String(repeating: "One sentence. Another sentence! ", count: 50)
        let generated = plan(text, settings: settings())
        let pauses = generated.events.map(\.flight).filter { $0 >= 1_999 }
        #expect(pauses.count == 99)
        #expect(pauses.allSatisfy { $0 >= 1_999.999 && $0 <= 10_000.001 })
        #expect(pauses.contains { $0 > 8_000 })
        #expect(Set(pauses.map { Int($0) }).count > 20)
    }

    @Test func pauseDurationDoesNotScaleWithTypingSpeedOrRequireThoughtPauses() {
        for speed in [20.0, 150.0] {
            var settings = settings(minimum: 10, maximum: 10)
            settings.wpm = speed
            let generated = plan("First. Second.", settings: settings)
            let wait = generated.events[6].flight
            #expect(abs(wait - 10_000) < 0.001)
        }
    }

    @Test func disablingPausesKeepsTextRepairsAndOriginalTiming() {
        let text = String(repeating: "their because definitely receive separate about. Another sentence! ", count: 20)
        var enabled = settings()
        enabled.mode = .natural
        enabled.mistakeLevel = 5
        var disabled = enabled
        disabled.sentencePauses = false
        let original = plan(text, settings: disabled)
        let paused = plan(text, settings: enabled)
        #expect(original.repairs > 0 && paused.repairs == original.repairs)
        #expect(paused.events.map(\.kind) == original.events.map(\.kind))
        #expect(paused.events.map(\.value) == original.events.map(\.value))
        // Normalization subtracts larger absolute offsets after the pauses.
        #expect(zip(paused.events, original.events).allSatisfy { abs($0.dwell - $1.dwell) < 0.001 })
        #expect(paused.duration > original.duration)
        #expect(zip(paused.events, original.events).allSatisfy { $0.flight + 0.001 >= $1.flight })
        var changedRange = enabled
        changedRange.sentencePauseMinimum = 4
        changedRange.sentencePauseMaximum = 4
        let changed = plan(text, settings: changedRange)
        #expect(changed.events.map(\.value) == original.events.map(\.value))
    }

    @Test func overlappingThoughtPausesUseTheLongerWait() {
        var enabled = settings(minimum: 2, maximum: 2)
        enabled.thoughtPauses = true
        enabled.extendedThoughtPauses = true
        var disabled = enabled
        disabled.sentencePauses = false
        let text = String(repeating: "One sentence. Another sentence! ", count: 100)
        let original = plan(text, settings: disabled)
        let paused = plan(text, settings: enabled)
        var longer = 0
        for (before, after) in zip(original.events, paused.events) where before.flight > 2_000 {
            #expect(abs(before.flight - after.flight) < 0.001)
            longer += 1
        }
        #expect(longer > 0)
    }

    @Test func oldSettingsDecodeAndMalformedRangesStayBounded() throws {
        var original = settings()
        original.wpm = 92
        var json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(original)) as? [String: Any])
        for key in ["sentencePauses", "sentencePauseMinimum", "sentencePauseMaximum"] { json.removeValue(forKey: key) }
        let decoded = try JSONDecoder().decode(TypingSettings.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(!decoded.sentencePauses && decoded.sentencePauseSeconds == 2...10)
        #expect(decoded.wpm == 92 && decoded.mode == .clean && !decoded.thoughtPauses)
        #expect(try JSONDecoder().decode(TypingSettings.self, from: JSONEncoder().encode(original)) == original)
        original.sentencePauseMinimum = Int.max
        original.sentencePauseMaximum = Int.min
        #expect(original.sentencePauseSeconds == 1...60)
    }
}
