import AppKit
import ApplicationServices
import Foundation

@MainActor
final class AppModel: ObservableObject {
    @Published var section: AppSection = .compose
    @Published var guideTopic: GuideTopic = .firstRun
    @Published var sourceText = "Hey — quick update. I finished the first pass and pushed the changes. There are still a couple of rough edges, but the core flow is working really well now." {
        didSet { schedulePreviewRefresh() }
    }
    @Published var settings = TypingSettings() {
        didSet { schedulePreviewRefresh() }
    }
    @Published var trainingMode: TrainingMode = .copy
    @Published var showsSystemSetup = false
    @Published var toast: String?
    @Published private(set) var accessibilityAuthorized = false
    @Published private(set) var inputMonitoringAuthorized = false
    @Published private(set) var previewPlan = TypingPlan(events: [], duration: 0, repairs: 0, effectiveWPM: 0)

    let profiles: ProfileStore
    let controller = TypingController()
    let liveCapture = GlobalTrainingCapture()
    private var previewTask: Task<Void, Never>?
    private var previewRevision = 0
    private var previewAppliedRevision = 0

    init(profileStore: ProfileStore? = nil) {
        profiles = profileStore ?? ProfileStore()
        if CommandLine.arguments.contains("--train") { section = .train }
        if CommandLine.arguments.contains("--profiles") { section = .profiles }
        if CommandLine.arguments.contains("--live-capture") {
            section = .train
            trainingMode = .liveCapture
        }
        profiles.onChange = { [weak self] in self?.schedulePreviewRefresh() }
        refreshPermissions()
        refreshPreviewImmediately()
    }

    func paste() {
        if let value = NSPasteboard.general.string(forType: .string) { sourceText = value }
        else { showToast("The clipboard does not contain text.") }
    }

    func showGuide(_ topic: GuideTopic) {
        guideTopic = topic
        section = .guide
    }

    func arm() {
        guard !sourceText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        guard !liveCapture.isCapturing else {
            showToast("Stop Live capture before starting playback.")
            return
        }
        refreshPermissions()
        if !accessibilityAuthorized {
            showsSystemSetup = true
            requestAccessibilityPermission()
            return
        }
        if previewAppliedRevision == previewRevision, !previewPlan.events.isEmpty {
            controller.start(plan: previewPlan)
        } else {
            controller.start(text: sourceText, settings: playbackSettings, profile: playbackProfile)
        }
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

    func requestInputMonitoringPermission() {
        _ = CGRequestListenEventAccess()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            self?.refreshPermissions()
        }
    }

    func refreshPermissions() {
        let trusted = AXIsProcessTrusted()
        if trusted != accessibilityAuthorized { accessibilityAuthorized = trusted }
        let canListen = CGPreflightListenEventAccess()
        if canListen != inputMonitoringAuthorized { inputMonitoringAuthorized = canListen }
    }

    func openInputMonitoringSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent") else { return }
        NSWorkspace.shared.open(url)
    }

    func showToast(_ message: String) {
        toast = message
        Task {
            try? await Task.sleep(for: .seconds(2.8))
            if toast == message { toast = nil }
        }
    }

    private func refreshPreviewImmediately() {
        previewPlan = Self.makePreview(text: sourceText, settings: playbackSettings, profile: playbackProfile)
        previewAppliedRevision = previewRevision
    }

    private func schedulePreviewRefresh() {
        previewTask?.cancel()
        previewRevision += 1
        let revision = previewRevision
        let text = sourceText
        let settings = playbackSettings
        let profile = playbackProfile
        previewTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(120))
            guard !Task.isCancelled else { return }
            let plan = await Task.detached(priority: .userInitiated) {
                Self.makePreview(text: text, settings: settings, profile: profile)
            }.value
            guard !Task.isCancelled, let self, revision == self.previewRevision else { return }
            self.previewPlan = plan
            self.previewAppliedRevision = revision
        }
    }

    private nonisolated static func makePreview(text: String, settings: TypingSettings, profile: TypingProfile) -> TypingPlan {
        // Timing controls intentionally do not change the preview's random typo
        // choices. Variation changes cadence; Mistake frequency changes repairs.
        let seedMaterial = "\(text)|\(settings.mode.rawValue)|\(settings.mistakeLevel)|\(settings.delayedRepairs)|\(profile.id)"
        var generator = SeededGenerator(seed: stableSeed(seedMaterial))
        return TypingEngine.generatePlan(text: text, settings: settings, profile: profile, using: &generator)
    }

    private nonisolated static func stableSeed(_ value: String) -> UInt64 {
        value.utf8.reduce(14_695_981_039_346_656_037) { hash, byte in
            (hash ^ UInt64(byte)) &* 1_099_511_628_211
        }
    }

    var playbackProfile: TypingProfile {
        settings.mode == .personal
            ? profiles.activeProfile
            : .baseline(wpm: settings.wpm)
    }

    var playbackSettings: TypingSettings {
        var result = settings
        if settings.mode == .clean { result.mistakeLevel = 0 }
        return result
    }

    var isUsingLearnedProfile: Bool {
        settings.mode == .personal && profiles.activeProfile.sampleCount > 0
    }

    var performanceSourceTitle: String {
        isUsingLearnedProfile ? "Using your profile" : "Using generic rhythm"
    }

    var performanceSourceDetail: String {
        if isUsingLearnedProfile {
            let profile = profiles.activeProfile
            let count = profile.sampleCount
            return "\(profile.name) · \(count) sample\(count == 1 ? "" : "s") · \(profile.isLegacy ? "playback only" : "research-stabilized")"
        }
        switch settings.mode {
        case .personal: return "No saved samples yet—using the built-in model"
        case .natural: return "Research-informed timing and correction habits"
        case .clean: return "Human cadence with generated mistakes disabled"
        }
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
