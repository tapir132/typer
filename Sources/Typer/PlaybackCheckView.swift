import SwiftUI
import UniformTypeIdentifiers

@MainActor
struct PlaybackCheckView: View {
    @StateObject private var controller = PlaybackCheckController()
    @Environment(\.dismiss) private var dismiss
    @State private var exportError: String?

    init() {}

    init(controller: PlaybackCheckController) {
        _controller = StateObject(wrappedValue: controller)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Check playback on this Mac").font(.title2.weight(.semibold))
                    Text("See what a real editor receives. No training samples needed.")
                        .font(.subheadline).foregroundStyle(TyperTheme.mutedStrong)
                }
                Spacer()
                Button("Done") { controller.close(); dismiss() }
                    .buttonStyle(SecondaryButtonStyle()).disabled(controller.isRunning)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text("Choose a short built-in test. It types only into the editor below; keep this window focused and avoid typing during the check.")
                        .font(.system(size: 12)).foregroundStyle(TyperTheme.mutedStrong)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack {
                        Picker("Test", selection: $controller.scenario) {
                            ForEach(PlaybackCheckScenario.allCases) { Text($0.rawValue).tag($0) }
                        }.labelsHidden().pickerStyle(.segmented).disabled(controller.isRunning)
                        HelpTip(title: "What each check covers", text: "Rhythm checks overlapping keys, repeated physical keys and Shift changes. Corrections checks Backspace, word deletion, selection replacement and cursor insertion. Unicode checks punctuation, accented text, emoji, Return and Tab. These are fixed test plans, not a measure of your personal profile.")
                    }
                    PlaybackCheckReceiver(controller: controller)
                        .frame(height: 100).typerSurface()
                        .overlay(RoundedRectangle(cornerRadius: 12).stroke(TyperTheme.line, lineWidth: 1))
                    HStack {
                        Text(controller.status).font(.system(size: 11)).foregroundStyle(TyperTheme.mutedStrong)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 12)
                        if controller.isRunning {
                            Button("Stop check") { controller.stop() }.keyboardShortcut(.escape, modifiers: [])
                                .buttonStyle(SecondaryButtonStyle())
                        } else {
                            Button(controller.report == nil ? "Run check" : "Run again") { exportError = nil; controller.start() }
                                .buttonStyle(SecondaryButtonStyle())
                                .help("About \(Int(ceil(controller.scenario.fixture.plan.duration / 1_000))) seconds, plus a short wait for final events.")
                        }
                    }
                    if let report = controller.report { results(report) }
                    else {
                        Divider()
                        Label("This checks delivery, not whether typing is human.", systemImage: "info.circle")
                            .font(.system(size: 12, weight: .medium))
                        Text("It shares the playback scheduler with Compose, but sends events directly to Typer. Other apps, input methods and keyboard layouts can behave differently. Use Validate rhythm to compare generated timing with your saved sessions.")
                            .font(.system(size: 12)).foregroundStyle(TyperTheme.mutedStrong)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }.padding(.trailing, 4)
            }
            HStack {
                Text("Local only · results are kept in memory unless exported").font(.caption).foregroundStyle(TyperTheme.mutedStrong)
                Spacer()
                if let report = controller.report {
                    Button("Export report…") { export(report) }.buttonStyle(SecondaryButtonStyle())
                }
            }
            if let exportError { Text(exportError).font(.caption).foregroundStyle(TyperTheme.danger) }
        }
        .padding(24)
        .frame(width: 820, height: min(730, (NSScreen.main?.visibleFrame.height ?? 810) - 80))
        .foregroundStyle(TyperTheme.ink).background(TyperTheme.background)
        .onDisappear { controller.close() }
    }

    private func results(_ report: PlaybackCheckReport) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Divider()
            HStack {
                Label(report.integrityPassed ? "Text and events match" : "Review this run",
                      systemImage: report.integrityPassed ? "checkmark.circle" : "exclamationmark.circle")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(report.integrityPassed ? TyperTheme.signal : TyperTheme.ink)
                Spacer()
                Text(report.inputSource).font(.caption).foregroundStyle(TyperTheme.mutedStrong)
            }
            HStack(spacing: 24) {
                value("Exact text", report.textMatches ? "Matches" : "Different")
                value("Events received", "\(report.receivedEvents) / \(report.expectedEvents)")
                value("Missing / extra", "\(report.missingEvents) / \(report.duplicateEvents + report.unexpectedEvents)")
                value("Order / flags errors", "\(report.outOfOrderEvents) / \(report.modifierMismatches)")
            }
            if !report.textMatches {
                Text("Expected: \(report.expectedText.debugDescription)")
                    .font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
                Text("If no text arrived, check Accessibility permission. If characters differ, check your keyboard layout or input method; playback currently maps physical keys as US QWERTY.")
                    .font(.caption).foregroundStyle(TyperTheme.mutedStrong)
            }
            HStack(spacing: 4) {
                Text("Timing error").font(.system(size: 13, weight: .semibold))
                HelpTip(title: "Timing error", text: "Absolute difference between planned timing and the time the editor handles events, in milliseconds. Median describes the typical difference; p95 is the nearest-rank 95th percentile. Smaller is closer to the plan. A text/event pass does not mean timing passed a threshold.")
            }
            Grid(alignment: .leading, horizontalSpacing: 28, verticalSpacing: 8) {
                GridRow {
                    Text("Measurement"); Text("Median"); Text("p95"); Text("Count")
                }.font(.caption).foregroundStyle(TyperTheme.mutedStrong)
                ForEach(report.timingErrors, id: \.name) { metric in
                    GridRow {
                        Text(metric.name)
                        Text(number(metric.median) + " ms")
                        Text(number(metric.p95) + " ms")
                        Text("\(metric.count)")
                    }.font(.system(size: 11, design: .monospaced))
                }
            }
            Text("Rollover: planned \(percent(report.plannedRollover)) · received \(percent(report.receivedRollover)) · \(report.comparedCharacterPairs) complete neighboring pairs")
                .font(.system(size: 11)).foregroundStyle(TyperTheme.mutedStrong)
            DisclosureGroup("How to interpret this check") {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(report.limitations, id: \.self) { Text($0).font(.caption).foregroundStyle(TyperTheme.mutedStrong) }
                }.padding(.top, 6)
            }.font(.system(size: 12))
        }
    }

    private func value(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption).foregroundStyle(TyperTheme.mutedStrong)
            Text(value).font(.system(size: 12, weight: .medium, design: .monospaced))
        }
    }

    private func number(_ value: Double?) -> String { value.map { String(format: "%.1f", $0) } ?? "—" }
    private func percent(_ value: Double?) -> String { value.map { String(format: "%.0f%%", $0 * 100) } ?? "—" }

    private func export(_ report: PlaybackCheckReport) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "typer-playback-check.json"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(report).write(to: url, options: .atomic)
        } catch { exportError = "Could not export the check: \(error.localizedDescription)" }
    }
}
