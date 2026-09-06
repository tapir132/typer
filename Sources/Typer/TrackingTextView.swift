import AppKit
import SwiftUI

struct CapturedKey {
    var keyCode: UInt16
    var characters: String
    var timestamp: Double
    var cursor: Int
    var isRepeat: Bool
    var modifiers: NSEvent.ModifierFlags = []
}

struct TrackingTextView: NSViewRepresentable {
    @Binding var text: String
    var placeholder: String
    var onKeyDown: (CapturedKey) -> Void
    var onKeyUp: (CapturedKey) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true

        let initialSize = NSSize(width: 640, height: 220)
        let textView = TrainingEditorFactory.make(text: text, placeholder: placeholder, size: initialSize)
        textView.delegate = context.coordinator
        textView.onKeyDown = onKeyDown
        textView.onKeyUp = onKeyUp
        scrollView.documentView = textView
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? CapturingNSTextView else { return }
        context.coordinator.parent = self
        textView.onKeyDown = onKeyDown
        textView.onKeyUp = onKeyUp
        if textView.string != text {
            let selection = textView.selectedRange()
            textView.string = text
            textView.setSelectedRange(NSRange(location: min(selection.location, text.utf16.count), length: 0))
        }
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: TrackingTextView
        init(parent: TrackingTextView) { self.parent = parent }
        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            parent.text = textView.string
            textView.needsDisplay = true
        }
    }
}

enum TrainingEditorFactory {
    static func make(text: String, placeholder: String, size: NSSize) -> CapturingNSTextView {
        let textView = CapturingNSTextView(frame: NSRect(origin: .zero, size: size))
        textView.isEditable = true
        textView.isSelectable = true
        textView.isRichText = false
        textView.importsGraphics = false
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.minSize = NSSize(width: 0, height: size.height)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.textContainer?.containerSize = NSSize(width: size.width, height: CGFloat.greatestFiniteMagnitude)
        textView.textContainer?.widthTracksTextView = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isContinuousSpellCheckingEnabled = false
        textView.allowsUndo = true
        textView.drawsBackground = false
        textView.textColor = NSColor(red: 0.946, green: 0.944, blue: 0.972, alpha: 1)
        textView.insertionPointColor = NSColor(red: 0.67, green: 0.93, blue: 0.24, alpha: 1)
        textView.font = .monospacedSystemFont(ofSize: 14, weight: .regular)
        textView.textContainerInset = NSSize(width: 15, height: 14)
        textView.string = text
        textView.placeholder = placeholder
        textView.needsDisplay = true
        return textView
    }
}

final class CapturingNSTextView: NSTextView {
    var onKeyDown: ((CapturedKey) -> Void)?
    var onKeyUp: ((CapturedKey) -> Void)?
    var placeholder = ""

    override var acceptsFirstResponder: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard string.isEmpty, !placeholder.isEmpty else { return }
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: 14, weight: .regular),
            .foregroundColor: NSColor(red: 0.56, green: 0.555, blue: 0.64, alpha: 1)
        ]
        placeholder.draw(
            at: NSPoint(x: textContainerInset.width + 5, y: textContainerInset.height),
            withAttributes: attributes
        )
    }

    override func keyDown(with event: NSEvent) {
        onKeyDown?(CapturedKey(
            keyCode: event.keyCode,
            characters: event.characters ?? "",
            timestamp: event.timestamp * 1_000,
            cursor: selectedRange().location,
            isRepeat: event.isARepeat,
            modifiers: event.modifierFlags
        ))
        super.keyDown(with: event)
        needsDisplay = true
    }

    override func keyUp(with event: NSEvent) {
        onKeyUp?(CapturedKey(
            keyCode: event.keyCode,
            characters: event.characters ?? "",
            timestamp: event.timestamp * 1_000,
            cursor: selectedRange().location,
            isRepeat: event.isARepeat,
            modifiers: event.modifierFlags
        ))
        super.keyUp(with: event)
    }
}
