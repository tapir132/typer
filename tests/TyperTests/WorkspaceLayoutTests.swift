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
            try await snapshot(RootView(model: model).systemSetup, name: "SystemSetup", size: NSSize(width: 500, height: 780))
            for topic in GuideTopic.allCases {
                model.guideTopic = topic
                try await snapshot(AppGuideView(model: model), name: "Guide-\(topic.rawValue)", size: NSSize(width: 920, height: 1600))
            }
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
