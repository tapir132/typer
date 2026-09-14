import Foundation

/// Exploratory leave-one-session-out diagnostics for a private snapshot. These
/// are development measurements, not the in-app four-session validation gate.
@main struct ProfileAudit {
    struct Snapshot: Decodable { var profile: TypingProfile; var samples: [TrainingSample]; var settings: TypingSettings }
    struct Report: Encodable {
        var exploratory = true
        var limitations = ["Each fold trains on the other retained sessions only. Three seeds are repeated simulations, not additional human sessions.",
            "Older recordings may not verify final text. Such trials retain textMatched=false; prompt identity alone does not prove completion.",
            "This measures planned timelines. It does not measure browser delivery or establish generalization after development on these data."]
        var trials: [ValidationTrial]
        var overview: [ValidationOverviewRow]
    }
    @MainActor static func main() throws {
        let args = CommandLine.arguments
        guard args.count == 3 else { fatalError("Usage: profile-audit SNAPSHOT.json REPORT.json") }
        let snapshot = try JSONDecoder().decode(Snapshot.self, from: Data(contentsOf: URL(fileURLWithPath: args[1])))
        let samples = TypingValidation.eligibleSamples(snapshot.samples, mode: .copy)
        guard samples.count >= 3 else { fatalError("Three comparable Copy samples are required for this exploratory audit.") }
        var trials: [ValidationTrial] = []
        for held in samples.indices {
            let indices = samples.indices.filter { $0 != held }
            let profile = TypingEngine.merge(samples: indices.map { samples[$0] })
            let reference = samples[held]
            let text = reference.referenceText ?? TypingValidation.referenceText
            for seed: UInt64 in [17, 41, 89] {
                for mode in [TypingSettings.Mode.natural, .personal] {
                    var settings = TypingSettings(); settings.mode = mode; settings.wpm = profile.wpm
                    var random = SeededGenerator(seed: seed)
                    let plan = TypingEngine.generatePlan(text: text, settings: settings,
                        profile: mode == .personal ? profile : .baseline(wpm: profile.wpm), using: &random)
                    trials.append(ValidationTrial(heldOutSession: held + 1, trainingSessions: indices.map { $0 + 1 },
                        seed: seed, mode: mode.rawValue, wpm: settings.wpm,
                        textMatched: reference.referenceText != nil && reference.referenceCompleted == true,
                        comparison: TypingValidation.compare(reference: reference.evidence!, candidate: TypingValidation.evidence(for: plan))))
                }
            }
        }
        let report = Report(trials: trials, overview: TypingValidation.overview(trials: trials, humanToHuman: nil))
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(report).write(to: URL(fileURLWithPath: args[2]), options: .atomic)
    }
}
