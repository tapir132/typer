import SwiftUI

struct TrainingCoverageView: View {
    let profile: TypingProfile

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("\(profile.name) · \(profile.trainingMode?.rawValue ?? (profile.isLegacy ? "Legacy" : "context not recorded"))")
                .font(.system(size: 12, weight: .semibold))
            if let evidence = profile.evidence {
                Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 12) {
                    row("Key timing", count: "\(evidence.pairs.count) paired timings",
                        supported: evidence.pairs.count >= 120, advice: "Longer natural samples provide more timing evidence.")
                    row("Rollover", count: "\(evidence.pairs.values.count) retained pairs",
                        supported: evidence.pairs.values.count >= 120, advice: "Completed key releases are needed; zero observed overlap can be valid.")
                    row("Corrections", count: "\(evidence.deletionRuns.count) deletion runs",
                        supported: evidence.deletionRuns.count >= 10, advice: "Correct real errors normally. Do not invent mistakes for training.")
                    if profile.trainingMode != .liveCapture {
                        ForEach(PauseContext.allCases, id: \.rawValue) { context in
                            let value = evidence.pauseContexts?[context.rawValue]
                            row(context.label,
                                count: value.map { "\($0.pauseCount) pause\($0.pauseCount == 1 ? "" : "s") / \($0.opportunities) opportunities · \($0.sessions) session\($0.sessions == 1 ? "" : "s")" }
                                    ?? (evidence.pauseContexts == nil ? "Not recorded in older samples" : "No eligible boundaries recorded"),
                                supported: value?.isSupported == true,
                                advice: "Learns after 20 opportunities, 3 observed pauses and 2 sessions. Keep typing naturally.")
                        }
                    }
                }
                if profile.trainingMode == .liveCapture {
                    Text("Thinking pauses aren't learned in Live capture. Use Freewrite to teach those.")
                        .font(.system(size: 11)).foregroundStyle(TyperTheme.mutedStrong)
                }
                Text("These counts describe the evidence used by this profile. “Available” is a support check, not proof of realism. Pause categories use punctuation and spacing; abbreviations can be ambiguous. Validate against fresh sessions before drawing conclusions.")
                    .font(.system(size: 11)).foregroundStyle(TyperTheme.mutedStrong)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text(profile.isLegacy
                     ? "Legacy statistics remain available for playback. New recordings build a separate My rhythm profile with timing and pause evidence."
                     : "The baseline has no personal recordings. Train My rhythm to see your coverage here.")
                    .font(.system(size: 12)).foregroundStyle(TyperTheme.mutedStrong)
            }
        }
    }

    private func row(_ title: String, count: String, supported: Bool, advice: String) -> some View {
        GridRow {
            HStack(spacing: 4) {
                Text(title)
                HelpTip(title: title, text: advice)
            }
            Text(count).foregroundStyle(TyperTheme.mutedStrong)
            Text(supported ? "Available" : "Collect more")
                .foregroundStyle(supported ? TyperTheme.signal : TyperTheme.mutedStrong)
        }.font(.system(size: 11))
    }
}
