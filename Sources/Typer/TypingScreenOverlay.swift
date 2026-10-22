import AppKit
import SwiftUI

final class TypingOverlayPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    init(screenFrame: NSRect, interactive: Bool = false) {
        super.init(contentRect: screenFrame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isReleasedWhenClosed = false
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        ignoresMouseEvents = !interactive
        hidesOnDeactivate = false
        level = .statusBar
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
    }
}

/// Buttons accept the first click without activating Typer or moving the target
/// field's keyboard focus. The separate tint window still passes clicks through.
final class TypingOverlayHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

@MainActor
final class TypingScreenOverlay {
    private var panels: [NSPanel] = []
    private var screens: [NSRect] = []
    private let content = TypingOverlayPresentation()
    var onPauseResume: (() -> Void)?
    var onSkipWait: (() -> Void)?
    var onStop: (() -> Void)?
    var onSaveLater: (() -> Void)?

    func update(state: RunState, progress: PlaybackProgress, target: String, message: String?, enabled: Bool, shortcuts: ShortcutBindings = ShortcutBindings(), stopText: String? = nil, canSaveLater: Bool = false, saving: Bool = false) {
        guard enabled && state.isPlaybackActive else { hide(); return }
        content.paused = state == .paused
        content.progress = progress
        content.target = target
        content.message = message
        content.shortcuts = shortcuts
        content.stopText = stopText
        content.canSaveLater = canSaveLater
        content.saving = saving
        let frames = NSScreen.screens.map(\.frame)
        if frames != screens {
            hide(); screens = frames
            for frame in frames {
                let tint = TypingOverlayPanel(screenFrame: frame)
                tint.contentView = NSHostingView(rootView: TypingOverlayTint(presentation: content))
                tint.orderFrontRegardless()
                panels.append(tint)
                let cardSize = NSSize(width: min(640, frame.width - 48), height: min(470, frame.height - 48))
                let cardFrame = NSRect(x: frame.midX - cardSize.width / 2, y: frame.midY - cardSize.height / 2,
                                       width: cardSize.width, height: cardSize.height)
                let controls = TypingOverlayPanel(screenFrame: cardFrame, interactive: true)
                let host = TypingOverlayHostingView(rootView: TypingOverlayHost(presentation: content,
                    onPauseResume: { [weak self] in self?.onPauseResume?() },
                    onSkipWait: { [weak self] in self?.onSkipWait?() }, onStop: { [weak self] in self?.onStop?() },
                    onSaveLater: { [weak self] in self?.onSaveLater?() }))
                host.sizingOptions = []
                controls.contentView = host
                controls.orderFrontRegardless()
                panels.append(controls)
            }
        }
    }

    func hide() {
        for panel in panels { panel.orderOut(nil); panel.close() }
        panels = []; screens = []
    }
}

@MainActor
private final class TypingOverlayPresentation: ObservableObject {
    @Published var paused = false
    @Published var progress = PlaybackProgress()
    @Published var target = ""
    @Published var message: String?
    @Published var shortcuts = ShortcutBindings()
    @Published var stopText: String?
    @Published var canSaveLater = false
    @Published var saving = false
}

private struct TypingOverlayTint: View {
    @ObservedObject var presentation: TypingOverlayPresentation
    var body: some View { TypingOverlayContent.tint(paused: presentation.paused).ignoresSafeArea() }
}

private struct TypingOverlayHost: View {
    @ObservedObject var presentation: TypingOverlayPresentation
    var onPauseResume: () -> Void
    var onSkipWait: () -> Void
    var onStop: () -> Void
    var onSaveLater: () -> Void
    var body: some View {
        TypingOverlayContent(paused: presentation.paused, progress: presentation.progress,
            target: presentation.target, message: presentation.message, shortcuts: presentation.shortcuts,
            stopText: presentation.stopText, showsTint: false, onPauseResume: onPauseResume,
            onSkipWait: onSkipWait, onStop: onStop, canSaveLater: presentation.canSaveLater, onSaveLater: onSaveLater, saving: presentation.saving)
    }
}

struct TypingOverlayContent: View {
    var paused: Bool
    var progress: PlaybackProgress
    var target: String
    var message: String?
    var shortcuts = ShortcutBindings()
    var stopText: String?
    var showsTint = true
    var onPauseResume: () -> Void = {}
    var onSkipWait: () -> Void = {}
    var onStop: () -> Void = {}
    var canSaveLater = true
    var onSaveLater: () -> Void = {}
    var saving = false

    static func tint(paused: Bool) -> Color {
        Color(red: 0.7, green: 0.015, blue: 0.035).opacity(paused ? 0.14 : 0.28)
    }

    var body: some View {
        ZStack {
            if showsTint { Self.tint(paused: paused) }
            VStack(spacing: 18) {
                Text(paused ? "Typing paused" : "Typer is typing")
                    .font(.system(size: 28, weight: .semibold))
                Text(shortcuts.pause.displayText)
                    .font(.system(size: 60, weight: .bold, design: .monospaced))
                    .lineLimit(1).minimumScaleFactor(0.4)
                    .accessibilityLabel("Pause and resume shortcut: \(shortcuts.pause.displayText)")
                Text(message ?? (paused ? "Keep the original field focused in \(target)." : "Sending keys to \(target)"))
                    .font(.system(size: 14)).multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                Text(paused ? "Paused. Save below to return later." : progress.activity)
                    .font(.system(size: 16, weight: .medium)).monospacedDigit()
                ProgressView(value: progress.fraction).tint(.white)
                    .accessibilityLabel("Typing progress")
                HStack(spacing: 12) {
                    Button(action: onPauseResume) {
                        Label(paused ? "Resume typing" : "Pause typing", systemImage: paused ? "play.fill" : "pause.fill")
                            .frame(minWidth: 150, minHeight: 32)
                    }
                    .buttonStyle(.borderedProminent).tint(.white).foregroundStyle(Color(red: 0.2, green: 0.02, blue: 0.04))
                    .help("\(shortcuts.pause.displayText) also pauses and resumes")
                    .accessibilityIdentifier("overlay.pauseResume")
                    .disabled(saving)
                    Button("Stop", action: onStop)
                        .buttonStyle(.bordered).controlSize(.large)
                        .help("\(stopText ?? shortcuts.stop.displayText) · keeps your place in Typer. Choose Save and resume later before quitting.")
                        .accessibilityIdentifier("overlay.stop")
                }
                Button(saving ? "Saving…" : "Save and resume later", action: onSaveLater)
                    .buttonStyle(.bordered).controlSize(.large)
                    .disabled(!canSaveLater)
                    .help("Save this run and its text on this Mac, so you can quit Typer and continue another time.")
                    .accessibilityIdentifier("overlay.saveLater")
                Button("Skip this wait · \(shortcuts.skipWait.displayText)", action: onSkipWait)
                    .buttonStyle(.borderless).font(.system(size: 13, weight: .medium))
                    .disabled(paused || !progress.canSkipWait)
                    .opacity(paused || !progress.canSkipWait ? 0.55 : 1)
                    .accessibilityIdentifier("overlay.skipWait")
            }
            .foregroundStyle(.white)
            .padding(30).frame(maxWidth: 600)
            .background(Color(red: 0.16, green: 0.015, blue: 0.025).opacity(0.98))
            .clipShape(RoundedRectangle(cornerRadius: 16))
            .padding(16)
        }
        .ignoresSafeArea()
        .environment(\.colorScheme, .dark)
    }
}
