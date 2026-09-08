import AppKit
import SwiftUI

final class TypingOverlayPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    init(screenFrame: NSRect) {
        super.init(contentRect: screenFrame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isReleasedWhenClosed = false
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        ignoresMouseEvents = true
        hidesOnDeactivate = false
        level = .statusBar
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
    }
}

@MainActor
final class TypingScreenOverlay {
    private var panels: [NSPanel] = []
    private var screens: [NSRect] = []
    private let content = TypingOverlayPresentation()

    func update(state: RunState, progress: PlaybackProgress, target: String, message: String?, enabled: Bool) {
        guard enabled && state.isPlaybackActive else { hide(); return }
        content.paused = state == .paused
        content.progress = progress
        content.target = target
        content.message = message
        let frames = NSScreen.screens.map(\.frame)
        if frames != screens {
            hide(); screens = frames
            for frame in frames {
                let panel = TypingOverlayPanel(screenFrame: frame)
                panel.contentView = NSHostingView(rootView: TypingOverlayHost(presentation: content))
                panel.orderFrontRegardless()
                panels.append(panel)
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
}

private struct TypingOverlayHost: View {
    @ObservedObject var presentation: TypingOverlayPresentation
    var body: some View {
        TypingOverlayContent(paused: presentation.paused, progress: presentation.progress,
                             target: presentation.target, message: presentation.message)
    }
}

struct TypingOverlayContent: View {
    var paused: Bool
    var progress: PlaybackProgress
    var target: String
    var message: String?

    var body: some View {
        ZStack {
            Color(red: 0.7, green: 0.015, blue: 0.035).opacity(paused ? 0.14 : 0.28)
            VStack(spacing: 22) {
                Text(paused ? "TYPING PAUSED" : "TYPER IS TYPING")
                    .font(.system(size: 19, weight: .bold)).tracking(3)
                Text("⌘ ⌥ P").font(.system(size: 72, weight: .bold, design: .monospaced))
                Text(paused ? "Press to resume" : "Press to pause")
                    .font(.system(size: 32, weight: .semibold))
                Text(message ?? (paused ? "Focus the same field in \(target), then resume." : "Sending keys to \(target)"))
                    .font(.system(size: 15)).multilineTextAlignment(.center)
                if !paused { Text(progress.activity).font(.system(size: 17, weight: .medium)) }
                HStack(spacing: 36) {
                    Text("⌘ Esc / ⌃ Esc   Stop")
                    Text("⌘ ⌥ →   Skip long wait")
                }.font(.system(size: 14, weight: .semibold, design: .monospaced))
                ProgressView(value: progress.fraction).tint(.white).frame(width: 360)
            }
            .foregroundStyle(.white)
            .padding(42).frame(maxWidth: 720)
            .background(Color(red: 0.16, green: 0.015, blue: 0.025).opacity(0.96))
            .clipShape(RoundedRectangle(cornerRadius: 16))
            .padding(24)
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .accessibilityElement(children: .combine)
    }
}
