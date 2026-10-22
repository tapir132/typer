import Foundation

/// An in-memory editor for previewing the exact planned edits. No keyboard
/// event is posted to macOS and no preview text is persisted.
struct PreviewTextBuffer {
    private(set) var characters: [Character] = []
    private(set) var cursor = 0
    private var anchor: Int?
    var text: String { String(characters) }
    var selectedRange: NSRange {
        let start = min(anchor ?? cursor, cursor), end = max(anchor ?? cursor, cursor)
        let offset = String(characters.prefix(start)).utf16.count
        return NSRange(location: offset, length: String(characters[start..<end]).utf16.count)
    }

    mutating func apply(_ event: PlannedEvent) {
        func bounds() -> Range<Int> { min(anchor ?? cursor, cursor)..<max(anchor ?? cursor, cursor) }
        func eraseSelection() -> Bool {
            let range = bounds()
            anchor = nil
            guard !range.isEmpty else { return false }
            characters.removeSubrange(range); cursor = range.lowerBound; return true
        }
        switch event.kind {
        case .character, .enter, .tab:
            _ = eraseSelection()
            let value = Array(event.kind == .enter ? "\n" : event.kind == .tab ? "\t" : event.value)
            characters.insert(contentsOf: value, at: cursor); cursor += value.count
        case .backspace:
            if !eraseSelection(), cursor > 0 { characters.remove(at: cursor - 1); cursor -= 1 }
        case .wordBackspace:
            if !eraseSelection() {
                let end = cursor
                while cursor > 0 && characters[cursor - 1].isWhitespace { cursor -= 1 }
                while cursor > 0 && !characters[cursor - 1].isWhitespace { cursor -= 1 }
                characters.removeSubrange(cursor..<end)
            }
        case .arrowLeft:
            cursor = anchor == nil ? max(0, cursor - 1) : bounds().lowerBound; anchor = nil
        case .arrowRight:
            cursor = anchor == nil ? min(characters.count, cursor + 1) : bounds().upperBound; anchor = nil
        case .shiftArrowLeft:
            if anchor == nil { anchor = cursor }
            cursor = max(0, cursor - 1)
        }
    }
}
