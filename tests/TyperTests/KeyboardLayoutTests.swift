import Carbon
import Foundation
import Testing
@testable import Typer

struct KeyboardLayoutTests {
    @MainActor @Test func installedLayoutsResolveTheirOwnLettersWithoutSelectingThem() throws {
        let before = KeyboardLayout.currentIdentifier()
        let us = KeyboardLayout.us
        let french = try #require(KeyboardLayout.installed(identifier: "com.apple.keylayout.French"))
        let german = try #require(KeyboardLayout.installed(identifier: "com.apple.keylayout.German"))
        #expect(us.sequence(for: "a")?.last?.code == 0)
        #expect(french.sequence(for: "a")?.last?.code == 12)
        #expect(french.sequence(for: "é")?.count == 1)
        #expect(german.sequence(for: "z")?.last?.code == 16)
        #expect(german.sequence(for: "ü")?.count == 1)
        #expect(KeyboardLayout.currentIdentifier() == before)
    }

    @Test func accentsUseDeadKeySequencesAndExactUnicodeFallbackIsPreserved() throws {
        for character in "éàñüêÉÜ" {
            let keys = try #require(KeyboardLayout.us.sequence(for: String(character)))
            #expect(keys.count == 2)
            #expect(keys[0].option)
        }
        #expect(KeyboardLayout.us.sequence(for: "e\u{301}") == nil)
        #expect(KeyboardLayout.us.sequence(for: "🙂") == nil)
        #expect(KeyDescriptor(event: PlannedEvent(kind: .character, value: "é", flight: 0, dwell: 80)).unicode.isEmpty)
    }

    @MainActor @Test func everyMappedSequenceTranslatesToExactTextWithoutPendingComposition() throws {
        for identifier in ["com.apple.keylayout.US", "com.apple.keylayout.French", "com.apple.keylayout.German", "com.apple.keylayout.British", "com.apple.keylayout.Dvorak"] {
            let map = try #require(KeyboardLayout.installed(identifier: identifier))
            let sources = try #require(TISCreateInputSourceList([kTISPropertyInputSourceID as String: identifier] as CFDictionary, true)?.takeRetainedValue() as? [TISInputSource])
            let source = try #require(sources.first)
            let property = try #require(TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData))
            let data = Unmanaged<CFData>.fromOpaque(property).takeUnretainedValue()
            let layout = UnsafeRawPointer(try #require(CFDataGetBytePtr(data))).assumingMemoryBound(to: UCKeyboardLayout.self)
            for (text, keys) in map.mappings {
                var state: UInt32 = 0, length = 0, buffer = [UniChar](repeating: 0, count: 16)
                for (index, key) in keys.enumerated() {
                    let flags = UInt32((key.option ? optionKey : 0) | (key.shift ? shiftKey : 0)) >> 8
                    #expect(UCKeyTranslate(layout, key.code, UInt16(kUCKeyActionDown), flags, UInt32(LMGetKbdType()), 0,
                        &state, buffer.count, &length, &buffer) == noErr)
                    if index < keys.count - 1 { #expect(state != 0) }
                }
                #expect(String(utf16CodeUnits: buffer, count: length).utf8.elementsEqual(text.utf8))
                #expect(UCKeyTranslate(layout, 49, UInt16(kUCKeyActionDown), 0, UInt32(LMGetKbdType()), 0,
                    &state, buffer.count, &length, &buffer) == noErr)
                #expect(String(utf16CodeUnits: buffer, count: length) == " ")
                #expect(state == 0)
            }
        }
    }

    @Test func physicalScheduleBalancesKeysAndKeepsModifiersAroundTheirLetters() {
        let events = "aA—…ééÉb🙂".map { PlannedEvent(kind: .character, value: String($0), flight: -100, dwell: 90) }
        let normalized = KeyTimeline.normalized(events)
        let again = KeyTimeline.normalized(normalized.events)
        for (a, b) in zip(again.events, normalized.events) {
            #expect(abs(a.flight - b.flight) < 0.000001 && abs(a.dwell - b.dwell) < 0.000001)
        }
        let actions = KeyTimeline.physicalActions(for: normalized.events)
        var held = Set<UInt16>(), shift = false, option = false
        for action in actions {
            if action.isDown { #expect(!held.contains(action.code)); held.insert(action.code) }
            else { #expect(held.remove(action.code) != nil) }
            if action.code == 56 { shift = action.isDown }
            if action.code == 58 { option = action.isDown }
            #expect(action.shift == shift && action.option == option)
            if let index = action.eventIndex {
                let expected = KeyDescriptor(event: events[index])
                #expect(action.shift == expected.shift && action.option == expected.option)
                if action.isDown && (expected.shift || expected.option) {
                    let downs = actions.filter { $0.isDown && ($0.code == 56 || $0.code == 58) && $0.scheduledOffset! < action.scheduledOffset! }
                    #expect(!downs.isEmpty)
                }
            }
        }
        #expect(held.isEmpty)
        #expect(actions.filter { $0.isDown && $0.eventIndex != nil }.compactMap(\.eventIndex) == Array(events.indices))
        #expect(actions.filter { $0.isCompositionPrefix && $0.isDown }.count == 3)
        #expect(normalized.duration == actions.last?.scheduledOffset)
    }

    @Test func cancelDuringAccentDismissesCompositionAndCannotEmitMoreText() {
        let events = [PlannedEvent(kind: .character, value: "é", flight: 0, dwell: 90)]
        let actions = KeyTimeline.physicalActions(for: events)
        for split in 0...actions.count {
            var output: [PhysicalKeyAction] = []
            let session = PlaybackSession { output.append($0); return true }
            for action in actions.prefix(split) { #expect(session.perform(action)) }
            session.cancel()
            let count = output.count
            for action in actions.dropFirst(split) { #expect(!session.perform(action)) }
            #expect(output.count == count)
            let pending = actions.prefix(split).contains { $0.isDown && $0.isCompositionPrefix } && !actions.prefix(split).contains { $0.isDown && $0.eventIndex != nil }
            #expect(output.filter { $0.isCompositionCleanup && $0.isDown }.count == (pending ? 1 : 0))
            var held = Set<UInt16>()
            for action in output { if action.isDown { held.insert(action.code) } else { held.remove(action.code) } }
            #expect(held.isEmpty)
        }
    }

    @Test func failedModifierReleaseIsRetriedDuringCleanup() {
        let events = [PlannedEvent(kind: .character, value: "A", flight: 0, dwell: 90)]
        var held = Set<UInt16>(), failedOnce = false, shiftUps = 0
        let session = PlaybackSession { action in
            if action.code == 56 && !action.isDown {
                shiftUps += 1
                if !failedOnce { failedOnce = true; return false }
            }
            if action.isDown { held.insert(action.code) } else { held.remove(action.code) }
            return true
        }
        for action in KeyTimeline.physicalActions(for: events) { _ = session.perform(action) }
        #expect(failedOnce && shiftUps == 2 && held.isEmpty)
    }

    @Test func skippingLongWaitPreservesAccentAndModifierLeadTimes() {
        let events = [PlannedEvent(kind: .character, value: "É", flight: 5_000, dwell: 90)]
        let n = KeyTimeline.normalized(events)
        var skips = 0, output: [(PhysicalKeyAction, Double)] = []
        let session = PlaybackSession { output.append(($0, ProcessInfo.processInfo.systemUptime)); return true }
        let outcome = session.run(plan: TypingPlan(events: n.events, duration: n.duration, repairs: 0, effectiveWPM: 0), onProgress: { progress in
            if progress.canSkipWait { skips += 1; #expect(session.skipWait()) }
        })
        #expect(outcome == .complete)
        #expect(skips == 1)
        let prefix = output.first { $0.0.isDown && $0.0.isCompositionPrefix }!
        let letter = output.first { $0.0.isDown && $0.0.eventIndex != nil }!
        #expect(letter.1 - prefix.1 >= 0.14)
    }

    @Test func runningAccentCanPauseReplayAndCommitOnlyOnce() {
        var output: [PhysicalKeyAction] = [], didPause = false
        let events = [PlannedEvent(kind: .character, value: "é", flight: 0, dwell: 90)]
        let n = KeyTimeline.normalized(events)
        let session = PlaybackSession { output.append($0); return true }
        let outcome = session.run(plan: TypingPlan(events: n.events, duration: n.duration, repairs: 0, effectiveWPM: 0), onProgress: { _ in
            if !didPause && output.contains(where: { $0.isCompositionPrefix && $0.isDown }) {
                didPause = true; session.pause(); session.resume()
            }
        })
        #expect(outcome == .complete && didPause)
        #expect(output.filter { $0.isCompositionPrefix && $0.isDown }.count == 2)
        #expect(output.filter { $0.isDown && $0.eventIndex != nil }.count == 1)
        #expect(output.filter { $0.isCompositionCleanup && $0.isDown }.count == 1)
    }
}
