import SwiftUI
import UniformTypeIdentifiers

struct ValidationView: View {
    let samples: [TrainingSample]
    @Environment(\.dismiss) private var dismiss
    @State private var report: ValidationReport?
    @State private var trialIndex = 0
    @State private var exportError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Validate your rhythm").font(.title2.weight(.semibold))
                    Text("Local comparisons against sessions the model has not trained on.").foregroundStyle(.secondary)
                }
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            if let report {
                Text(report.status).font(.headline)
                if !report.trials.isEmpty {
                    Picker("Comparison", selection: $trialIndex) {
                        Text("Human session vs human session").tag(-1)
                        ForEach(Array(report.trials.enumerated()), id: \.offset) { index, trial in
                            Text("Session \(trial.heldOutSession) · \(trial.mode) · seed \(trial.seed)").tag(index)
                        }
                    }
                    if let comparison = selectedComparison(report) {
                        HStack(spacing: 24) {
                            metric("Rollover", comparison.referenceRollover, comparison.candidateRollover, help: QuickHelp.rollover, percent: true)
                            metric("Interval correlation", comparison.referenceAutocorrelation, comparison.candidateAutocorrelation, help: "How neighboring press intervals vary together, from −1 to 1. Near zero means little linear relationship. The first value is human; the second is the candidate.")
                            metric("Deletes / character", comparison.referenceEditsPerCharacter, comparison.candidateEditsPerCharacter, help: QuickHelp.corrections)
                        }.font(.caption)
                        Text("Observed pairs: \(comparison.referenceObservedPairs) / \(comparison.candidateObservedPairs) · Missing holds: \(comparison.referenceMissingHolds) / \(comparison.candidateMissingHolds)")
                            .font(.caption).foregroundStyle(.secondary)
                        ScrollView([.horizontal, .vertical]) {
                            Grid(alignment: .leading, horizontalSpacing: 20, verticalSpacing: 9) {
                                GridRow {
                                    Text("Feature"); Text("Human median"); Text("Candidate median")
                                    HStack(spacing: 2) { Text("W1 distance"); HelpTip(title: "W1 distance", text: QuickHelp.w1) }
                                    HStack(spacing: 2) { Text("KS distance"); HelpTip(title: "KS distance", text: QuickHelp.ks) }
                                    HStack(spacing: 2) { Text("Retained n"); HelpTip(title: "Retained count", text: "Number of stored observations used for this feature: human / candidate. Storage is bounded, so these counts can be smaller than the total observed pairs.") }
                                }.font(.caption.weight(.semibold))
                                Divider().gridCellUnsizedAxes(.horizontal)
                                ForEach(comparison.distributions, id: \.name) { item in
                                    GridRow {
                                        Text(item.name)
                                        Text(number(item.referenceMedian) + " " + item.unit)
                                        Text(number(item.candidateMedian) + " " + item.unit)
                                        Text(number(item.wassersteinDistance) + " " + item.unit)
                                        Text(number(item.ksDistance, decimals: 3))
                                        Text("\(item.referenceCount) / \(item.candidateCount)")
                                    }.font(.system(size: 11, design: .monospaced))
                                }
                            }.frame(maxWidth: .infinity, alignment: .leading)
                        }
                        Text("Lower distances mean closer distributions. A dash means unavailable. Small samples can be misleading; compare with human-to-human variation.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                } else {
                    Text("Save at least four Copy sessions for matched-text comparisons. Freewrite and Live capture use a standard passage because their original text is not stored.")
                    Spacer()
                }
                DisclosureGroup("Definitions and limitations") {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 7) {
                            ForEach(report.limitations, id: \.self) { Text($0).font(.caption).foregroundStyle(.secondary) }
                        }
                    }.frame(maxHeight: 140)
                }
                HStack {
                    Text("\(report.context) · stays on this Mac").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Export report…") { export(report) }
                }
                if let exportError { Text(exportError).font(.caption).foregroundStyle(.red) }
            } else {
                Spacer(); ProgressView("Comparing sessions…"); Spacer()
            }
        }
        .padding(24)
        .frame(width: 900, height: min(690, (NSScreen.main?.visibleFrame.height ?? 770) - 80))
        .task {
            let snapshot = samples
            let result = await Task.detached(priority: .userInitiated) { TypingValidation.evaluate(samples: snapshot) }.value
            guard !Task.isCancelled else { return }
            report = result
        }
    }

    private func selectedComparison(_ report: ValidationReport) -> TraceComparison? {
        if trialIndex == -1 { return report.humanToHuman }
        return report.trials.indices.contains(trialIndex) ? report.trials[trialIndex].comparison : nil
    }

    private func metric(_ title: String, _ reference: Double?, _ candidate: Double?, help: String, percent: Bool = false) -> some View {
        let scale = percent ? 100.0 : 1.0
        return VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 3) { Text(title).foregroundStyle(.secondary); HelpTip(title: title, text: help) }
            Text("\(number(reference.map { $0 * scale })) / \(number(candidate.map { $0 * scale }))\(percent ? "%" : "")")
        }
    }

    private func number(_ value: Double?, decimals: Int = 1) -> String {
        value.map { String(format: "%.*f", decimals, $0) } ?? "—"
    }

    private func export(_ report: ValidationReport) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "typer-validation.json"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(report).write(to: url, options: .atomic)
        } catch { exportError = "Could not export the report: \(error.localizedDescription)" }
    }
}
