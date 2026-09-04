import AppKit
import ApplicationServices
import Foundation

@MainActor
final class AppModel: ObservableObject {
    @Published var section: AppSection = .compose
    @Published var sourceText = "Hey — quick update. I finished the first pass and pushed the changes. There are still a couple of rough edges, but the core flow is working really well now."
    @Published var settings = TypingSettings()
    @Published var showsSystemSetup = false
    @Published var toast: String?
    @Published private(set) var accessibilityAuthorized = false

    let profiles = ProfileStore()
    let controller = TypingController()

    init() {
        if CommandLine.arguments.contains("--train") { section = .train }
        if CommandLine.arguments.contains("--profiles") { section = .profiles }
        refreshPermissions()
    }

    func paste() {
        if let value = NSPasteboard.general.string(forType: .string) { sourceText = value }
        else { showToast("The clipboard does not contain text.") }
    }

    func arm() {
        guard !sourceText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        refreshPermissions()
        if !accessibilityAuthorized {
            showsSystemSetup = true
            requestAccessibilityPermission()
            return
        }
        controller.start(text: sourceText, settings: playbackSettings, profile: playbackProfile)
    }

    func requestAccessibilityPermission() {
        // Match Dictation's documented trust prompt. Publishing the result after
        // a short delay lets the setup sheet react without being reopened.
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            self?.refreshPermissions()
        }
    }

    func refreshPermissions() {
        let trusted = AXIsProcessTrusted()
        if trusted != accessibilityAuthorized { accessibilityAuthorized = trusted }
    }

    func showToast(_ message: String) {
        toast = message
        Task {
            try? await Task.sleep(for: .seconds(2.8))
            if toast == message { toast = nil }
        }
    }

    var previewPlan: TypingPlan {
        // Timing controls intentionally do not change the preview's random typo
        // choices. Variation changes cadence; Mistake frequency changes repairs.
        let seedMaterial = "\(sourceText)|\(settings.mode.rawValue)|\(settings.mistakeLevel)|\(settings.delayedRepairs)|\(playbackProfile.id)"
        var generator = SeededGenerator(seed: stableSeed(seedMaterial))
        return TypingEngine.generatePlan(text: sourceText, settings: playbackSettings, profile: playbackProfile, using: &generator)
    }

    private func stableSeed(_ value: String) -> UInt64 {
        value.utf8.reduce(14_695_981_039_346_656_037) { hash, byte in
            (hash ^ UInt64(byte)) &* 1_099_511_628_211
        }
    }

    var playbackProfile: TypingProfile {
        settings.mode == .personal ? profiles.activeProfile : .baseline(wpm: settings.wpm)
    }

    var playbackSettings: TypingSettings {
        var result = settings
        if settings.mode == .clean { result.mistakeLevel = 0 }
        return result
    }
}

struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed == 0 ? 0x9E3779B97F4A7C15 : seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
}
