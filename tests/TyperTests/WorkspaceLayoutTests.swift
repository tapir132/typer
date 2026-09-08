import AppKit
import SwiftUI
import Testing
@testable import Typer

@MainActor
struct WorkspaceLayoutTests {
    @Test func switchingSectionsKeepsHeaderAtTheSameWindowPosition() async throws {
        _ = NSApplication.shared
        // Exercise a real older-profile row without reading or changing the
        // user's saved profiles. Longer copy must not shift the shared header.
        let suite = "typer.layout.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        var olderProfile = TypingProfile.baseline()
        olderProfile.id = UUID()
        olderProfile.name = "My rhythm"
        olderProfile.sampleCount = 4
        let text = String(repeating: "the quick brown fox ", count: 3)
        let records = text.enumerated().map { index, character in
            TrainingKeyRecord(id: UUID(), kind: .character, key: String(character), expected: String(character),
                              pressTime: Double(index) * 110, dwell: 95, cursor: index)
        }
        let freshSample = TypingEngine.summarize(records: records, target: text, duration: Double(text.count) * 110, mode: .copy)
        var olderSample = freshSample
        olderSample.evidence = nil
        olderSample.mode = nil
        olderSample.capturedAt = nil
        olderSample.referenceText = nil
        defaults.set(try JSONEncoder().encode([olderProfile]), forKey: "typer.profiles.v1")
        defaults.set(try JSONEncoder().encode(Array(repeating: olderSample, count: 4)), forKey: "typer.samples.v1")
        defaults.set(olderProfile.id.uuidString, forKey: "typer.activeProfile.v1")
        let model = AppModel(profileStore: ProfileStore(defaults: defaults))
        model.settings.mode = .personal
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1240, height: 800),
                              styleMask: [.titled, .closable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false
        window.setFrameOrigin(NSPoint(x: -10_000, y: -10_000))
        var headerFrame: CGRect?
        let host = NSHostingView(rootView: RootView(model: model, onHeaderFrameChange: { headerFrame = $0 }).preferredColorScheme(.dark))
        host.sizingOptions = []
        window.contentView = host
        window.orderBack(nil)
        defer { window.close() }
        for size in [NSSize(width: 1240, height: 800), NSSize(width: 920, height: 660)] {
            window.setContentSize(size)
            var headerBottoms: [Int] = []
            for section in AppSection.allCases + [.compose] {
                model.section = section
                try await Task.sleep(for: .milliseconds(100))
                host.layoutSubtreeIfNeeded()
                let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                host.cacheDisplay(in: host.bounds, to: bitmap)
                if let directory = ProcessInfo.processInfo.environment["TYPER_LAYOUT_SNAPSHOTS"], let png = bitmap.representation(using: .png, properties: [:]) {
                    let url = URL(fileURLWithPath: directory, isDirectory: true)
                    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
                    try png.write(to: url.appendingPathComponent("\(section.rawValue)-\(Int(size.width))x\(Int(size.height)).png"))
                }
                let frame = try #require(headerFrame)
                headerBottoms.append(Int(frame.maxY.rounded()))
                #expect(frame.minY >= 0, "Header clipped at \(section.rawValue): \(frame)")
            }
            #expect(Set(headerBottoms).count == 1, "Header moved at \(size): \(headerBottoms)")
        }
        if ProcessInfo.processInfo.environment["TYPER_LAYOUT_SNAPSHOTS"] != nil {
            model.settings.sentencePauses = true
            model.section = .compose
            try await snapshot(RootView(model: model), name: "SentencePauses", size: NSSize(width: 1240, height: 900))
            model.settings.sentencePauses = false
            try await snapshot(SettingsView(model: model), name: "Settings-General", size: NSSize(width: 800, height: SettingsView.height))
            try await snapshot(PlaybackCheckView(), name: "PlaybackCheck-Ready", size: NSSize(width: 820, height: 730))
            try await snapshot(PlaybackPreviewView(plan: model.previewPlan, text: model.sourceText),
                               name: "PlaybackPreview-Ready", size: NSSize(width: 820, height: 690))
            let pausedPlan = TypingPlan(events: [
                PlannedEvent(kind: .character, value: "Hello.", flight: 0, dwell: 20),
                PlannedEvent(kind: .character, value: " Next sentence.", flight: 10_000, dwell: 20, pauseKind: .sentence)
            ], duration: 10_040, repairs: 0, effectiveWPM: 20)
            let preview = PlaybackPreviewController(plan: pausedPlan, text: "Hello. Next sentence.")
            preview.play()
            try await Task.sleep(for: .milliseconds(150))
            try await snapshot(PlaybackPreviewView(preview: preview), name: "PlaybackPreview-Wait", size: NSSize(width: 820, height: 690))
            preview.stop()
            let progress = PlaybackProgress(fraction: 0.35, remaining: 42, waitRemaining: 6.2, pauseKind: .sentence)
            for paused in [false, true] {
                try await snapshot(TypingOverlayContent(paused: paused, progress: progress, target: "TextEdit", message: nil),
                                   name: "ScreenOverlay-\(paused ? "Paused" : "Typing")", size: NSSize(width: 1240, height: 800))
            }
            var coverage = TypingEngine.merge(samples: [freshSample, freshSample])
            coverage.evidence?.pauseContexts = [
                "word": PauseDistribution(opportunities: 80, pauseCount: 5, durations: [2_000, 3_000, 4_000], sessions: 2),
                "sentence": PauseDistribution(opportunities: 10, pauseCount: 1, durations: [5_000], sessions: 1)
            ]
            try await snapshot(TrainingCoverageView(profile: coverage).padding(24),
                               name: "TrainingCoverage", size: NSSize(width: 824, height: 400))
            var completed = freshSample
            completed.referenceCompleted = true
            try await snapshot(ValidationView(samples: Array(repeating: completed, count: 4)), name: "Validation-Overview", size: NSSize(width: 900, height: 690))
            try await snapshot(ValidationView(samples: [freshSample]), name: "Validation-Readiness", size: NSSize(width: 900, height: 690))
            for topic in GuideTopic.allCases {
                model.settingsSection = .guide
                model.guideTopic = topic
                try await snapshot(SettingsView(model: model), name: "Settings-Guide-\(topic.rawValue)", size: NSSize(width: 800, height: SettingsView.height))
            }
            model.section = .train
            model.trainingMode = .liveCapture
            try await snapshot(RootView(model: model), name: "LiveCapture-IdleHelp", size: NSSize(width: 1240, height: 800))
            model.trainingMode = .copy
        }
        model.profiles.add(sample: freshSample)
        let reloaded = ProfileStore(defaults: defaults)
        #expect(reloaded.samples.count == 5)
        #expect(reloaded.legacySampleCount == 4)
        #expect(reloaded.activeProfile.sampleCount == 1)
        #expect(reloaded.activeProfile.evidence != nil)
        if ProcessInfo.processInfo.environment["TYPER_LAYOUT_SNAPSHOTS"] != nil {
            for section in [AppSection.train, .profiles] {
                model.section = section
                try await snapshot(RootView(model: model), name: "FiveSaved-OneUsed-\(section.rawValue)", size: NSSize(width: 920, height: 660))
            }
        }
    }

    @Test func settingsGuidePreservesTheUnfinishedTrainingEditor() async throws {
        _ = NSApplication.shared
        let suite = "typer.guide.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = AppModel(profileStore: ProfileStore(defaults: defaults))
        model.section = .train
        model.trainingMode = .freewrite
        let window = NSWindow(contentRect: NSRect(x: -10_000, y: -10_000, width: 1240, height: 800),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let host = NSHostingView(rootView: RootView(model: model))
        host.sizingOptions = []
        window.contentView = host
        window.orderBack(nil)
        defer { window.close() }
        try await Task.sleep(for: .milliseconds(100))
        let editor = try #require(trainingEditor(in: host))
        editor.insertText("An unfinished practice sentence.", replacementRange: NSRange(location: 0, length: 0))
        try await Task.sleep(for: .milliseconds(100))

        model.showGuide(.training)
        try await Task.sleep(for: .milliseconds(200))
        #expect(model.section == .train)
        #expect(window.attachedSheet != nil)
        model.guideTopic = .privacy
        model.settingsSection = .general
        model.showsSettings = false
        try await Task.sleep(for: .milliseconds(300))
        #expect(trainingEditor(in: host) === editor)
        #expect(editor.string == "An unfinished practice sentence.")
        #expect(model.trainingMode == .freewrite)
        #expect(model.profiles.samples.isEmpty)
    }

    private func trainingEditor(in view: NSView) -> CapturingNSTextView? {
        if let editor = view as? CapturingNSTextView { return editor }
        return view.subviews.lazy.compactMap { trainingEditor(in: $0) }.first
    }

    @Test func typingOverlayCannotTakeKeyboardOrMouseFocus() {
        _ = NSApplication.shared
        let panel = TypingOverlayPanel(screenFrame: NSRect(x: -10_000, y: -10_000, width: 1240, height: 800))
        defer { panel.close() }
        #expect(!panel.canBecomeKey && !panel.canBecomeMain)
        #expect(panel.ignoresMouseEvents && !panel.hidesOnDeactivate)
        #expect(panel.styleMask.contains(.nonactivatingPanel))
        #expect(panel.collectionBehavior.contains(.fullScreenAuxiliary))
        #expect(panel.level == .statusBar)
    }

    private func snapshot<Content: View>(_ view: Content, name: String, size: NSSize) async throws {
        guard let directory = ProcessInfo.processInfo.environment["TYPER_LAYOUT_SNAPSHOTS"] else { return }
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.setFrameOrigin(NSPoint(x: -10_000, y: -10_000))
        let host = NSHostingView(rootView: view.frame(width: size.width, height: size.height, alignment: .topLeading)
            .background(TyperTheme.background).preferredColorScheme(.dark))
        host.sizingOptions = []
        window.contentView = host
        window.orderBack(nil)
        defer { window.close() }
        try await Task.sleep(for: .milliseconds(100))
        host.layoutSubtreeIfNeeded()
        let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        let png = try #require(bitmap.representation(using: .png, properties: [:]))
        try png.write(to: URL(fileURLWithPath: directory).appendingPathComponent("\(name).png"))
    }
}
