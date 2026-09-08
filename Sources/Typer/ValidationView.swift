import SwiftUI
import UniformTypeIdentifiers

struct ValidationView: View {
    let samples: [TrainingSample]
    @Environment(\.dismiss) private var dismiss
    @State private var report: ValidationReport?
    @State private var trialIndex = 0
    @State private var exportError: String?
    @State private var context: TrainingMode
    @State private var showsOverview = true

    init(samples: [TrainingSample]) {
        self.samples = samples
        _context = State(initialValue: samples.last?.mode ?? .copy)
    }

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
            Picker("Training context", selection: $context) {
                ForEach(TrainingMode.allCases) { mode in
                    Text("\(mode.rawValue) · \(TypingValidation.eligibleSamples(samples, mode: mode).count) ready").tag(mode)
                }
            }
            Text(readinessExplanation)
                .font(.caption).foregroundStyle(.secondary)
            if let report {
                Text(report.status).font(.headline)
                if !report.trials.isEmpty {
                    Picker("Report view", selection: $showsOverview) {
                        Text("Overview").tag(true)
                        Text("Detailed trials").tag(false)
                    }.pickerStyle(.segmented)
                    if report.trials.contains(where: { !$0.textMatched }) {
                        Label("Text is unmatched or completion was not verified. Passage differences can affect these results.", systemImage: "info.circle")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    if showsOverview {
                        overview(report)
                    } else {
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
                                    if let rates = comparison.pauseRates {
                                        Divider().gridCellUnsizedAxes(.horizontal)
                                        GridRow {
                                            Text("Pause frequency"); Text("Human rate"); Text("Candidate rate")
                                            Text("Absolute gap"); Text("Pauses H / C"); Text("Opportunities H / C")
                                        }.font(.caption.weight(.semibold))
                                        ForEach(rates, id: \.name) { rate in
                                            GridRow {
                                                Text(rate.name)
                                                Text(number(rate.referenceFrequency.map { $0 * 100 }) + "%")
                                                Text(number(rate.candidateFrequency.map { $0 * 100 }) + "%")
                                                Text(number(rate.referenceFrequency.flatMap { a in rate.candidateFrequency.map { abs(a - $0) * 100 } }) + " pp")
                                                Text("\(rate.referencePauses.map(String.init) ?? "—") / \(rate.candidatePauses.map(String.init) ?? "—")")
                                                Text("\(rate.referenceOpportunities.map(String.init) ?? "—") / \(rate.candidateOpportunities.map(String.init) ?? "—")")
                                            }.font(.system(size: 11, design: .monospaced))
                                        }
                                    }
                                }.frame(minWidth: 852, alignment: .leading)
                            }
                            Text("Lower distances mean closer distributions. A dash means unavailable. Small samples can be misleading; compare with human-to-human variation.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                } else {
                    Text("\(report.eligibleSessions) of 4 ready \(context.rawValue) sessions. Save \(max(0, 4 - report.eligibleSessions)) more to compare this context. Finish Copy or Sprint passages exactly for verified matched-text comparisons. Your existing samples are kept.")
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
        .task(id: context) {
            report = nil
            trialIndex = 0
            exportError = nil
            let snapshot = samples, mode = context
            let result = await Task.detached(priority: .userInitiated) { TypingValidation.evaluate(samples: snapshot, mode: mode) }.value
            guard !Task.isCancelled else { return }
            report = result
        }
    }

    private var shortSessionCount: Int {
        samples.filter { !$0.isLegacy && $0.mode == context && ($0.evidence?.pairs.count ?? 0) < 20 }.count
    }

    private var readinessExplanation: String {
        let requirement = "Each ready session has at least 20 usable paired timings."
        guard shortSessionCount > 0 else { return requirement }
        return requirement + " \(shortSessionCount) shorter \(context.rawValue) \(shortSessionCount == 1 ? "sample is" : "samples are") excluded."
    }

    private func overview(_ report: ValidationReport) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 4) {
                Text("Natural and My rhythm, across every paired trial")
                    .font(.subheadline.weight(.semibold))
                HelpTip(title: "W1 distance", text: QuickHelp.w1)
            }
            Text("Each value is the median W1 distance across runs; the smaller range underneath shows the minimum and maximum. Lower means closer for that feature. A dash means there was no comparable evidence.")
                .font(.caption).foregroundStyle(.secondary)
            ScrollView([.horizontal, .vertical]) {
                Grid(alignment: .leading, horizontalSpacing: 20, verticalSpacing: 14) {
                    GridRow {
                        Text("Feature")
                        Text("Natural")
                        Text("My rhythm")
                        HStack(spacing: 3) {
                            Text("Human vs human")
                            HelpTip(title: "Human comparison", text: "W1 between the two held-out sessions. This gives context for normal within-person differences; it is not a pass threshold, and the sessions can contain different passages.")
                        }
                        Text("Paired runs")
                    }.font(.caption.weight(.semibold))
                    Divider().gridCellUnsizedAxes(.horizontal)
                    ForEach(report.overview ?? [], id: \.name) { item in
                        GridRow {
                            Text(item.name)
                            overviewValue(item.naturalMedianW1, range: item.naturalRange, unit: item.unit)
                            overviewValue(item.personalMedianW1, range: item.personalRange, unit: item.unit)
                            Text(item.humanToHumanW1.map { number($0) + " " + item.unit } ?? "—")
                            Text("\(item.pairedTrials)")
                        }.font(.system(size: 11, design: .monospaced))
                    }
                }.frame(minWidth: 852, alignment: .leading)
            }
            Text("Several seeds reuse the same two human sessions. They are not independent human tests. Open Detailed trials to inspect retained counts, missing holds, pause frequencies and opportunity counts. Duration distance alone does not describe how often a pause occurs.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func overviewValue(_ value: Double?, range: [Double], unit: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(value.map { number($0) + " " + unit } ?? "—")
            if range.count == 2 {
                Text("\(number(range[0]))–\(number(range[1]))").foregroundStyle(.secondary)
            }
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
