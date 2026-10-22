import AppKit
import SwiftUI
import Testing
@testable import Typer

@MainActor
struct OverlayControlsTests {
    @Test func overlayButtonsWorkWithoutBecomingTheKeyboardWindow() async throws {
        _ = NSApplication.shared
        let previousKey = NSApp.keyWindow
        let panel = TypingOverlayPanel(screenFrame: NSRect(x: -10_000, y: -10_000, width: 640, height: 470), interactive: true)
        defer { panel.close() }
        var pauses = 0, skips = 0, stops = 0, saves = 0
        let host = TypingOverlayHostingView(rootView: TypingOverlayContent(paused: false,
            progress: PlaybackProgress(fraction: 0.5, waitRemaining: 300, pauseKind: .paragraph),
            target: "Test editor", message: nil, showsTint: false,
            onPauseResume: { pauses += 1 }, onSkipWait: { skips += 1 }, onStop: { stops += 1 }, onSaveLater: { saves += 1 }))
        host.sizingOptions = []
        panel.contentView = host; panel.orderBack(nil)
        try await Task.sleep(for: .milliseconds(120))
        host.layoutSubtreeIfNeeded()
        let buttons = nativeButtons(in: host)
        try #require(buttons.count == 4)
        for button in buttons { button.performClick(nil) }
        try await Task.sleep(for: .milliseconds(30))
        #expect(pauses == 1 && skips == 1 && stops == 1 && saves == 1)
        #expect(!panel.isKeyWindow && NSApp.keyWindow === previousKey)
    }

    private func nativeButtons(in view: NSView) -> [NSButton] {
        if let button = view as? NSButton { return [button] }
        return view.subviews.flatMap { nativeButtons(in: $0) }
    }
}
