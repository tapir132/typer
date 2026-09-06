import Foundation

@MainActor
final class ProfileStore: ObservableObject {
    @Published private(set) var profiles: [TypingProfile] = []
    @Published private(set) var samples: [TrainingSample] = []
    @Published var activeProfileID: UUID = TypingProfile.baselineID {
        didSet {
            defaults.set(activeProfileID.uuidString, forKey: Keys.activeProfile)
            onChange?()
        }
    }
    var onChange: (() -> Void)?

    private let defaults: UserDefaults
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    private enum Keys {
        static let profiles = "typer.profiles.v1"
        static let samples = "typer.samples.v1"
        static let activeProfile = "typer.activeProfile.v1"
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Keys.profiles), let decoded = try? decoder.decode([TypingProfile].self, from: data) {
            profiles = decoded
        }
        if let data = defaults.data(forKey: Keys.samples), let decoded = try? decoder.decode([TrainingSample].self, from: data) {
            samples = decoded
        }
        if let rawID = defaults.string(forKey: Keys.activeProfile), let id = UUID(uuidString: rawID), id == TypingProfile.baselineID || profiles.contains(where: { $0.id == id }) {
            activeProfileID = id
        }
        preserveLegacyProfile()
    }

    var activeProfile: TypingProfile {
        profiles.first(where: { $0.id == activeProfileID }) ?? .baseline()
    }

    var legacySampleCount: Int { samples.filter(\.isLegacy).count }
    var currentSampleCount: Int { samples.count - legacySampleCount }

    var sampleUsageExplanation: String {
        var parts = ["A sample is one recorded typing session. A profile is built from selected samples."]
        parts.append("You have \(samples.count) saved samples: \(currentSampleCount) current and \(legacySampleCount) Legacy. The active profile was built from \(activeProfile.sampleCount).")
        parts.append("Saving a sample rebuilds My rhythm from up to five recent samples in that same mode.")
        if legacySampleCount > 0 {
            parts.append("Legacy profiles are locked for training and kept separately for playback. New samples never change them.")
        }
        return parts.joined(separator: " ")
    }

    var unusedOlderSamplesNote: String? {
        if activeProfile.isLegacy {
            return "Legacy profile selected for playback. New recordings go to My rhythm and leave this profile unchanged."
        }
        guard legacySampleCount > 0 else { return nil }
        return "\(currentSampleCount) current sample\(currentSampleCount == 1 ? "" : "s") · \(legacySampleCount) Legacy sample\(legacySampleCount == 1 ? "" : "s") kept separately for playback. Legacy profiles cannot accept new training."
    }

    @discardableResult func add(sample: TrainingSample) -> Bool {
        // Legacy data is read-only. All recording paths must supply the current
        // evidence and task context before they can create or update My rhythm.
        guard !sample.isLegacy else { return false }
        samples.append(sample)
        var excess = max(0, currentSampleCount - 12)
        samples.removeAll { sample in
            guard !sample.isLegacy, excess > 0 else { return false }
            excess -= 1
            return true
        }
        let matching = samples.filter { !$0.isLegacy && $0.mode == sample.mode }
        let recent = Array(matching.suffix(5))
        let existing = profiles.first(where: { !$0.isLegacy && $0.name == "My rhythm" })
        let learned = TypingEngine.merge(samples: recent, name: "My rhythm", id: existing?.id)
        if let index = profiles.firstIndex(where: { $0.id == learned.id }) { profiles[index] = learned }
        else { profiles.append(learned) }
        activeProfileID = learned.id
        persist()
        return true
    }

    func use(_ profile: TypingProfile) {
        activeProfileID = profile.id
    }

    func remove(_ profile: TypingProfile) {
        profiles.removeAll { $0.id == profile.id }
        if profile.isLegacy {
            // Remove the archive when its final profile is deleted so launch
            // migration cannot recreate a profile the user explicitly removed.
            if !profiles.contains(where: \.isLegacy) { samples.removeAll(where: \.isLegacy) }
        } else if profile.name == "My rhythm" {
            samples.removeAll { !$0.isLegacy }
        }
        if activeProfileID == profile.id { activeProfileID = TypingProfile.baselineID }
        persist()
    }

    func deleteAllLearnedData() {
        profiles.removeAll(); samples.removeAll()
        activeProfileID = TypingProfile.baselineID
        persist()
    }

    private func preserveLegacyProfile() {
        var changed = false
        for index in profiles.indices where profiles[index].isLegacy && profiles[index].name == "My rhythm" {
            // Keep the ID, timing statistics and active selection unchanged.
            profiles[index].name = "Legacy rhythm"
            changed = true
        }
        let legacySamples = samples.filter(\.isLegacy)
        if !legacySamples.isEmpty && !profiles.contains(where: \.isLegacy) {
            // Earlier versions overwrote My rhythm on the first new recording.
            // Recover a separate legacy summary from the still-saved samples.
            var legacy = TypingEngine.merge(samples: Array(legacySamples.suffix(5)), name: "Legacy rhythm")
            legacy.evidence = nil
            profiles.append(legacy)
            changed = true
        }
        if changed { persist() }
    }

    private func persist() {
        if let data = try? encoder.encode(profiles) { defaults.set(data, forKey: Keys.profiles) }
        if let data = try? encoder.encode(samples) { defaults.set(data, forKey: Keys.samples) }
    }
}
