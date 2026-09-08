import SwiftUI

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

@MainActor
final class PlaybackPreviewController: ObservableObject {
    @Published private(set) var buffer = PreviewTextBuffer()
    @Published private(set) var progress = PlaybackProgress()
    @Published private(set) var running = false
    @Published private(set) var paused = false
    @Published private(set) var status = "Watch the current plan, including its pauses and corrections."
    let plan: TypingPlan
    let expectedText: String
    private var session: PlaybackSession?
    private var token = UUID()
    private let queue = DispatchQueue(label: "typer.preview", qos: .userInitiated)

    init(plan: TypingPlan, text: String) { self.plan = plan; expectedText = text }

    deinit { session?.cancel() }

    func play() {
        stop()
        buffer = PreviewTextBuffer()
        progress = PlaybackProgress(remaining: plan.duration / 1_000)
        running = true; paused = false
        status = "Previewing"
        let token = UUID(); self.token = token
        let events = plan.events
        let session = PlaybackSession { [weak self] action in
            if action.isDown, let index = action.eventIndex {
                DispatchQueue.main.async {
                    guard let self, self.token == token, events.indices.contains(index) else { return }
                    self.buffer.apply(events[index])
                }
            }
            return true
        }
        self.session = session
        let plan = plan
        queue.async { [weak self] in
            let result = session.run(plan: plan, onProgress: { progress in
                DispatchQueue.main.async {
                    guard let self, self.token == token else { return }
                    var progress = progress
                    progress.isPaused = self.paused
                    self.progress = progress
                }
            })
            DispatchQueue.main.async {
                guard let self, self.token == token else { return }
                self.running = false; self.paused = false; self.session = nil
                self.status = result == .complete
                    ? (Array(self.buffer.text.utf8) == Array(self.expectedText.utf8) ? "Finished. Final text matches your source." : "Finished. Preview text differs from the source.")
                    : "Preview stopped."
            }
        }
    }

    func togglePause() {
        guard running else { return }
        if paused { session?.resume() } else { session?.pause() }
        paused.toggle()
        progress.isPaused = paused
    }
    func skipWait() { _ = session?.skipWait() }
    func stop() { session?.cancel(); session = nil; token = UUID(); running = false; paused = false; status = "Preview stopped." }
}

struct PlaybackPreviewView: View {
    @StateObject private var preview: PlaybackPreviewController
    @Environment(\.dismiss) private var dismiss

    init(plan: TypingPlan, text: String) {
        _preview = StateObject(wrappedValue: PlaybackPreviewController(plan: plan, text: text))
    }

    init(preview: PlaybackPreviewController) { _preview = StateObject(wrappedValue: preview) }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Preview your typing").font(.title2.weight(.semibold))
                    Text("Your text, pauses and repairs, played inside Typer.").foregroundStyle(TyperTheme.mutedStrong)
                }
                Spacer()
                Button("Done") { preview.stop(); dismiss() }.buttonStyle(SecondaryButtonStyle())
            }
            HStack {
                Text(preview.running ? (preview.paused ? "Paused" : preview.progress.activity) : preview.status)
                    .font(.system(size: 13, weight: .medium))
                Spacer()
                if preview.running { Text("\(Int(ceil(preview.progress.remaining))) s remaining").font(.system(size: 11, design: .monospaced)) }
            }
            PreviewEditor(buffer: preview.buffer)
                .typerSurface().overlay(RoundedRectangle(cornerRadius: 12).stroke(TyperTheme.line))
            ProgressView(value: preview.progress.fraction).tint(TyperTheme.primary)
            HStack {
                if preview.running {
                    Button(preview.paused ? "Resume" : "Pause") { preview.togglePause() }
                        .keyboardShortcut("p", modifiers: [.command, .option]).buttonStyle(SecondaryButtonStyle())
                    Button("Skip wait") { preview.skipWait() }
                        .keyboardShortcut(.rightArrow, modifiers: [.command, .option])
                        .buttonStyle(SecondaryButtonStyle()).disabled(preview.paused || !preview.progress.canSkipWait)
                    Button("Stop") { preview.stop() }.keyboardShortcut(.escape, modifiers: []).buttonStyle(QuietButtonStyle())
                } else {
                    Button(preview.buffer.text.isEmpty ? "Play preview" : "Replay") { preview.play() }.buttonStyle(SecondaryButtonStyle())
                }
                Spacer()
                HelpTip(title: "About this preview", text: "Uses the current plan and playback clock in an in-memory editor. It does not post keys to another app or require Accessibility. Skip wait shortens only this preview run; your settings and original plan stay unchanged. External editors may handle corrections or autocorrect differently.")
            }
            Text("⌘⌥P pause/resume · ⌘⌥→ skip a long wait · Esc stop preview")
                .font(.caption).foregroundStyle(TyperTheme.mutedStrong)
        }
        .padding(24).frame(width: 820, height: min(690, (NSScreen.main?.visibleFrame.height ?? 770) - 80))
        .foregroundStyle(TyperTheme.ink).background(TyperTheme.background)
        .onDisappear { preview.stop() }
    }
}

private struct PreviewEditor: NSViewRepresentable {
    let buffer: PreviewTextBuffer
    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.drawsBackground = false; scroll.hasVerticalScroller = true
        let editor = TrainingEditorFactory.make(text: "", placeholder: "Play preview to begin.", size: NSSize(width: 750, height: 380))
        editor.isEditable = false; editor.allowsUndo = false
        scroll.documentView = editor
        return scroll
    }
    func updateNSView(_ view: NSScrollView, context: Context) {
        guard let editor = view.documentView as? NSTextView else { return }
        if editor.string != buffer.text { editor.string = buffer.text }
        editor.setSelectedRange(buffer.selectedRange)
        editor.scrollRangeToVisible(buffer.selectedRange)
    }
}
