import AppKit
import SwiftUI

struct CapturedKey {
    var keyCode: UInt16
    var characters: String
    var timestamp: Double
    var cursor: Int
    var isRepeat: Bool
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
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true

        let textView = CapturingNSTextView()
        textView.delegate = context.coordinator
        textView.isRichText = false
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
        }
    }
}

private final class CapturingNSTextView: NSTextView {
    var onKeyDown: ((CapturedKey) -> Void)?
    var onKeyUp: ((CapturedKey) -> Void)?

    override func keyDown(with event: NSEvent) {
        onKeyDown?(CapturedKey(
            keyCode: event.keyCode,
            characters: event.characters ?? "",
            timestamp: event.timestamp * 1_000,
            cursor: selectedRange().location,
            isRepeat: event.isARepeat
        ))
        super.keyDown(with: event)
    }

    override func keyUp(with event: NSEvent) {
        onKeyUp?(CapturedKey(
            keyCode: event.keyCode,
            characters: event.characters ?? "",
            timestamp: event.timestamp * 1_000,
            cursor: selectedRange().location,
            isRepeat: event.isARepeat
        ))
        super.keyUp(with: event)
    }
}
