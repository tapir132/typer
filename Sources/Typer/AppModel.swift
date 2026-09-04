import AppKit
import Foundation

@MainActor
final class AppModel: ObservableObject {
    @Published var section: AppSection = .compose
    @Published var sourceText = "Hey — quick update. I finished the first pass and pushed the changes. There are still a couple of rough edges, but the core flow is working really well now."
    @Published var settings = TypingSettings()
    @Published var showsSystemSetup = false
    @Published var toast: String?

    let profiles = ProfileStore()
    let controller = TypingController()

    init() {
        if CommandLine.arguments.contains("--train") { section = .train }
        if CommandLine.arguments.contains("--profiles") { section = .profiles }
    }

    func paste() {
        if let value = NSPasteboard.general.string(forType: .string) { sourceText = value }
        else { showToast("The clipboard does not contain text.") }
    }

    func arm() {
        guard !sourceText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        if !controller.accessibilityGranted {
            showsSystemSetup = true
            _ = controller.requestAccessibility()
            return
        }
        controller.start(text: sourceText, settings: playbackSettings, profile: playbackProfile)
    }

    func showToast(_ message: String) {
        toast = message
        Task {
            try? await Task.sleep(for: .seconds(2.8))
            if toast == message { toast = nil }
        }
    }

    var previewPlan: TypingPlan {
        var generator = SeededGenerator(seed: UInt64(abs(sourceText.hashValue &+ Int(settings.wpm * 10))))
        return TypingEngine.generatePlan(text: sourceText, settings: playbackSettings, profile: playbackProfile, using: &generator)
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
