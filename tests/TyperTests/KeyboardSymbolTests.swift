import Carbon
import Testing
@testable import Typer

struct KeyboardSymbolTests {
    @Test func optionSymbolMappingsProduceTheirCharactersInApplesUSLayout() throws {
        let filter = [kTISPropertyInputSourceID as String: "com.apple.keylayout.US"] as CFDictionary
        let sources = try #require(TISCreateInputSourceList(filter, true)?.takeRetainedValue() as? [TISInputSource])
        let source = try #require(sources.first)
        let property = try #require(TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData))
        let data = Unmanaged<CFData>.fromOpaque(property).takeUnretainedValue()
        let bytes = try #require(CFDataGetBytePtr(data))
        let layout = UnsafeRawPointer(bytes).assumingMemoryBound(to: UCKeyboardLayout.self)
        for character in "–—“”‘’…•°©®™£€" {
            let key = try #require(KeyboardMap.lookup(String(character)))
            #expect(key.option)
            var state: UInt32 = 0, length = 0
            var output = [UniChar](repeating: 0, count: 8)
            let flags = UInt32(optionKey | (key.shift ? shiftKey : 0)) >> 8
            let result = UCKeyTranslate(layout, key.code, UInt16(kUCKeyActionDown), flags,
                                        UInt32(LMGetKbdType()), 0, &state, output.count, &length, &output)
            #expect(result == noErr)
            #expect(state == 0) // A direct character, never an unfinished accent.
            #expect(String(utf16CodeUnits: output, count: length) == String(character))
            let descriptor = KeyDescriptor(event: PlannedEvent(kind: .character, value: String(character), flight: 0, dwell: 70))
            #expect(descriptor.option && descriptor.unicode.isEmpty)
        }
        #expect(KeyboardMap.lookup("é") == nil)
        #expect(KeyboardMap.lookup("🙂") == nil)
    }

    @Test func optionPunctuationPreservesModifierBarriersAndCancellationCleanup() {
        let events = Array("a—…B").map { PlannedEvent(kind: .character, value: String($0), flight: -50, dwell: 100) }
        let strokes = KeyTimeline.strokes(for: events), actions = KeyTimeline.actions(for: strokes)
        for index in 1..<strokes.count { #expect(strokes[index].pressOffset >= strokes[index - 1].releaseOffset) }
        for split in 0...actions.count {
            var held = Set<UInt16>(), emitted: [PhysicalKeyAction] = []
            let session = PlaybackSession { action in
                emitted.append(action)
                if action.isDown { held.insert(action.code) } else { held.remove(action.code) }
                return true
            }
            for action in actions.prefix(split) { #expect(session.perform(action, events: events)) }
            session.cancel()
            #expect(held.isEmpty)
            #expect(!emitted.contains { $0.code == 0 && $0.unicode == "—" })
        }
        var output: [PhysicalKeyAction] = []
        let session = PlaybackSession { output.append($0); return true }
        for action in actions { #expect(session.perform(action, events: events)) }
        let dash = output.first { $0.eventIndex == 1 && $0.isDown }
        #expect(dash?.code == 27 && dash?.shift == true && dash?.option == true)
        #expect(output.filter { $0.code == 58 && $0.isDown }.count == 2)
        #expect(output.filter { $0.code == 58 && !$0.isDown }.count == 2)
    }
}
