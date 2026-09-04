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

    private let defaults = UserDefaults.standard
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    private enum Keys {
        static let profiles = "typer.profiles.v1"
        static let samples = "typer.samples.v1"
        static let activeProfile = "typer.activeProfile.v1"
    }

    init() {
        if let data = defaults.data(forKey: Keys.profiles), let decoded = try? decoder.decode([TypingProfile].self, from: data) {
            profiles = decoded
        }
        if let data = defaults.data(forKey: Keys.samples), let decoded = try? decoder.decode([TrainingSample].self, from: data) {
            samples = decoded
        }
        if let rawID = defaults.string(forKey: Keys.activeProfile), let id = UUID(uuidString: rawID), id == TypingProfile.baselineID || profiles.contains(where: { $0.id == id }) {
            activeProfileID = id
        }
    }

    var activeProfile: TypingProfile {
        profiles.first(where: { $0.id == activeProfileID }) ?? .baseline()
    }

    func add(sample: TrainingSample) {
        samples.append(sample)
        if samples.count > 12 { samples.removeFirst(samples.count - 12) }
        let recent = Array(samples.suffix(5))
        let existing = profiles.first(where: { $0.name == "My rhythm" })
        let learned = TypingEngine.merge(samples: recent, name: "My rhythm", id: existing?.id)
        if let index = profiles.firstIndex(where: { $0.id == learned.id }) { profiles[index] = learned }
        else { profiles.append(learned) }
        activeProfileID = learned.id
        persist()
    }

    func use(_ profile: TypingProfile) {
        activeProfileID = profile.id
    }

    func remove(_ profile: TypingProfile) {
        profiles.removeAll { $0.id == profile.id }
        if activeProfileID == profile.id { activeProfileID = TypingProfile.baselineID }
        persist()
    }

    private func persist() {
        if let data = try? encoder.encode(profiles) { defaults.set(data, forKey: Keys.profiles) }
        if let data = try? encoder.encode(samples) { defaults.set(data, forKey: Keys.samples) }
    }
}
