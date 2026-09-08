import Foundation

struct TypingPreset: Codable, Identifiable, Equatable {
    var id: UUID
    var name: String
    var settings: TypingSettings
    var builtIn: Bool

    static var defaults: [Self] {
        var quick = TypingSettings(); quick.wpm = 85; quick.sentencePauses = false
        var long = TypingSettings(); long.wpm = 60; long.sentencePauses = true
        var clean = TypingSettings(); clean.mode = .clean; clean.wpm = 100; clean.thoughtPauses = false
        return [
            Self(id: UUID(uuidString: "F088728A-5084-4A1D-9404-000000000001")!, name: "Quick messages", settings: quick, builtIn: true),
            Self(id: UUID(uuidString: "F088728A-5084-4A1D-9404-000000000002")!, name: "Long-form writing", settings: long, builtIn: true),
            Self(id: UUID(uuidString: "F088728A-5084-4A1D-9404-000000000003")!, name: "Clean copy", settings: clean, builtIn: true)
        ]
    }
}

@MainActor
final class SettingsStore: ObservableObject {
    @Published private(set) var presets: [TypingPreset]
    private let defaults: UserDefaults
    private let settingsKey = "typer.settings.v1"
    private let presetsKey = "typer.presets.v1"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let saved = defaults.data(forKey: presetsKey).flatMap { try? JSONDecoder().decode([TypingPreset].self, from: $0) } ?? []
        presets = TypingPreset.defaults + saved.filter { !$0.builtIn }.prefix(30).map {
            var preset = $0; preset.settings = preset.settings.sanitized; return preset
        }
    }

    var settings: TypingSettings {
        defaults.data(forKey: settingsKey).flatMap { try? JSONDecoder().decode(TypingSettings.self, from: $0) }?.sanitized ?? TypingSettings()
    }

    func save(_ settings: TypingSettings) {
        if let data = try? JSONEncoder().encode(settings.sanitized) { defaults.set(data, forKey: settingsKey) }
    }

    @discardableResult func add(name: String, settings: TypingSettings) -> TypingPreset? {
        let name = String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(60))
        guard !name.isEmpty, presets.filter({ !$0.builtIn }).count < 30,
              !presets.contains(where: { $0.name.localizedCaseInsensitiveCompare(name) == .orderedSame }) else { return nil }
        let preset = TypingPreset(id: UUID(), name: name, settings: settings.sanitized, builtIn: false)
        presets.append(preset); persist()
        return preset
    }

    func remove(_ id: UUID) {
        presets.removeAll { $0.id == id && !$0.builtIn }
        persist()
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(presets.filter { !$0.builtIn }) { defaults.set(data, forKey: presetsKey) }
    }
}

extension TypingSettings {
    var sanitized: Self {
        var copy = self
        copy.wpm = wpm.isFinite ? min(150, max(20, wpm)) : 64
        copy.variation = variation.isFinite ? min(1, max(0, variation)) : 0.78
        copy.mistakeLevel = min(5, max(0, mistakeLevel))
        copy.sentencePauseMinimum = sentencePauseSeconds.lowerBound
        copy.sentencePauseMaximum = sentencePauseSeconds.upperBound
        return copy
    }
}
