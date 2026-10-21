import Foundation
import Testing
@testable import Typer

struct ParagraphPauseTests {
    private func plan(_ text: String, settings: TypingSettings, seed: UInt64 = 42) -> TypingPlan {
        var random = SeededGenerator(seed: seed)
        return TypingEngine.generatePlan(text: text, settings: settings, profile: .baseline(), using: &random)
    }
    private var settings: TypingSettings {
        var settings = TypingSettings()
        settings.mode = .clean; settings.thoughtPauses = false; settings.paragraphPauses = true
        settings.paragraphPauseMinimum = 5; settings.paragraphPauseMaximum = 5
        return settings
    }

    @Test func pausesOnceBetweenParagraphsAfterTheSeparatorAndNeverAtTheEnd() {
        for (text, expected): (String, [String]) in [
            ("First paragraph.\n\nSecond paragraph.\nThird.", ["First paragraph.\n\n", "First paragraph.\n\nSecond paragraph.\n"]),
            ("\n\nFirst\n \t\nSecond\n\n", ["\n\nFirst\n \t\n"]),
            ("One paragraph.  ", []), ("\n \n", []),
            ("First\r\n\r\nSecond", ["First\r\n\r\n"]),
            ("First\u{2029}Second", ["First\u{2029}"])
        ] {
            let generated = plan(text, settings: settings)
            var prefix = "", prefixes: [String] = []
            for event in generated.events {
                if event.pauseKind == .paragraph {
                    prefixes.append(prefix)
                    #expect(abs(event.flight - 300_000) < 0.001)
                }
                prefix += event.value
            }
            #expect(prefix == text)
            #expect(prefixes == expected, "Paragraphs: \(text.debugDescription)")
            #expect(generated.duration == KeyTimeline.physicalActions(for: generated.events).last?.scheduledOffset)
        }
    }

    @Test func randomRangeAndFixedWaitAreIndependentOfWPMAndCleanMode() {
        var settings = settings; settings.paragraphPauseMaximum = 10
        let text = String(repeating: "Paragraph text.\n\n", count: 40)
        let generated = plan(text, settings: settings)
        let waits = generated.events.filter { $0.pauseKind == .paragraph }.map(\.flight)
        #expect(waits.count == 39)
        #expect(waits.allSatisfy { (299_999.999...600_000.001).contains($0) })
        #expect(Set(waits.map { Int($0) }).count > 20)
        for speed in [20.0, 150.0] {
            var fixed = self.settings; fixed.wpm = speed
            let wait = plan("One\nTwo", settings: fixed).events.first { $0.pauseKind == .paragraph }
            #expect(abs((wait?.flight ?? 0) - 300_000) < 0.001)
        }
    }

    @Test func paragraphAndSentenceWaitUseOneLongerBoundaryWait() {
        var settings = settings
        settings.sentencePauses = true; settings.sentencePauseMinimum = 10; settings.sentencePauseMaximum = 10
        let generated = plan("First. Next sentence.\n\nNew paragraph.\n", settings: settings)
        #expect(generated.events.filter { $0.pauseKind == .sentence }.count == 1)
        #expect(generated.events.filter { $0.pauseKind == .paragraph }.count == 1)
        #expect(generated.events.filter { $0.flight > 1_000 }.count == 2)
    }

    @Test func changingOrDisablingRangePreservesEveryGeneratedRepair() {
        let text = String(repeating: "their because definitely receive separate.\n\n", count: 15)
        var enabled = settings; enabled.mode = .natural; enabled.mistakeLevel = 5
        var disabled = enabled; disabled.paragraphPauses = false
        var changed = enabled; changed.paragraphPauseMaximum = 10
        let original = plan(text, settings: disabled)
        for modified in [enabled, changed] {
            let generated = plan(text, settings: modified)
            #expect(original.repairs > 0 && generated.repairs == original.repairs)
            #expect(generated.events.map(\.value) == original.events.map(\.value))
            #expect(generated.events.map(\.kind) == original.events.map(\.kind))
            var buffer = PreviewTextBuffer()
            for event in generated.events { buffer.apply(event) }
            #expect(buffer.text == text)
        }
        #expect(!original.events.contains { $0.pauseKind == .paragraph })
    }

    @Test func oldSettingsMigrateWithoutEnablingLongWaitsAndPresetsRoundTrip() throws {
        let old = Data(#"{"wpm":92,"sentencePauses":true}"#.utf8)
        let decoded = try JSONDecoder().decode(TypingSettings.self, from: old)
        #expect(!decoded.paragraphPauses && decoded.paragraphPauseMinutes == 5...10)
        #expect(decoded.wpm == 92 && decoded.sentencePauses)
        let original = settings
        #expect(try JSONDecoder().decode(TypingSettings.self, from: JSONEncoder().encode(original)) == original)
        var invalid = original; invalid.paragraphPauseMinimum = Int.max; invalid.paragraphPauseMaximum = Int.min
        #expect(invalid.paragraphPauseMinutes == 1...30)
        #expect(invalid.sanitized.paragraphPauseMinimum == 1 && invalid.sanitized.paragraphPauseMaximum == 30)
        #expect(PlaybackProgress(waitRemaining: 301, pauseKind: .paragraph).activity == "Paragraph pause · 5:01 remaining")
    }

    @Test func fiveMinuteWaitCanBePausedResumedAndSkippedWithoutChangingThePlan() {
        let generated = plan("A\nB", settings: settings)
        var output: [Int] = [], held = Set<UInt16>(), waits = 0
        let session = PlaybackSession { action in
            if action.isDown { held.insert(action.code) } else { held.remove(action.code) }
            if action.isDown, let index = action.eventIndex { output.append(index) }
            return true
        }
        let outcome = session.run(plan: generated, onProgress: { progress in
            if progress.canSkipWait, progress.pauseKind == .paragraph {
                waits += 1; session.pause()
                #expect(held.isEmpty && !session.skipWait())
                session.resume(); #expect(session.skipWait())
            }
        })
        #expect(outcome == .complete && waits == 1 && held.isEmpty)
        #expect(output == Array(generated.events.indices))
        #expect(generated.events.contains { $0.flight >= 299_999 })
    }
}
