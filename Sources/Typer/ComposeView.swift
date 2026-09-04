import SwiftUI

struct ComposeView: View {
    @ObservedObject var model: AppModel
    @ObservedObject private var controller: TypingController
    @ObservedObject private var profiles: ProfileStore

    init(model: AppModel) {
        self.model = model
        controller = model.controller
        profiles = model.profiles
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            heading
                .padding(.bottom, 26)
            HStack(alignment: .top, spacing: 0) {
                editor
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(.trailing, 30)
                controlRail
                    .frame(width: 306)
                    .padding(.leading, 28)
                    .overlay(alignment: .leading) { Rectangle().fill(TyperTheme.line).frame(width: 1) }
            }
            .overlay(alignment: .top) { Rectangle().fill(TyperTheme.line).frame(height: 1) }
            .overlay(alignment: .bottom) { Rectangle().fill(TyperTheme.line).frame(height: 1) }
        }
        .padding(.horizontal, TyperLayout.workspaceHorizontalPadding)
        .padding(.top, TyperLayout.workspaceTopPadding)
        .padding(.bottom, TyperLayout.workspaceBottomPadding)
    }

    private var heading: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 7) {
                Text("What should I type?").font(.system(size: 27, weight: .semibold)).tracking(-0.5)
                Text("Paste the finished text. Typer will perform the messy middle.").font(.system(size: 13)).foregroundStyle(TyperTheme.mutedStrong)
            }
            Spacer()
            HStack(spacing: 10) {
                Image(systemName: model.isUsingLearnedProfile ? "person.wave.2.fill" : "waveform.path")
                    .font(.system(size: 12, weight: .semibold)).foregroundStyle(model.isUsingLearnedProfile ? TyperTheme.signal : TyperTheme.mutedStrong)
                    .frame(width: 34, height: 34).background(TyperTheme.raised).clipShape(RoundedRectangle(cornerRadius: 9))
                VStack(alignment: .leading, spacing: 2) {
                    Text(model.performanceSourceTitle).font(.system(size: 9)).foregroundStyle(model.isUsingLearnedProfile ? TyperTheme.signal : TyperTheme.muted)
                    Text(model.performanceSourceDetail).font(.system(size: 11, weight: .semibold))
                }
            }
        }
    }

    private var editor: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Source text").font(.system(size: 11, weight: .medium)).foregroundStyle(TyperTheme.mutedStrong)
                Spacer()
                Button("Paste") { model.paste() }.buttonStyle(QuietButtonStyle())
                Button("Clear") { model.sourceText = "" }.buttonStyle(QuietButtonStyle())
            }
            .frame(height: 54)

            ZStack(alignment: .topLeading) {
                if model.sourceText.isEmpty {
                    Text("Paste or write something here…")
                        .font(.system(size: 15, design: .monospaced)).foregroundStyle(TyperTheme.muted)
                        .padding(.horizontal, 23).padding(.vertical, 26).allowsHitTesting(false)
                }
                TextEditor(text: $model.sourceText)
                    .font(.system(size: 15, design: .monospaced))
                    .lineSpacing(8)
                    .foregroundStyle(TyperTheme.ink)
                    .scrollContentBackground(.hidden)
                    .padding(18)
            }
            .background(TyperTheme.surface)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .frame(minHeight: 260)

            HStack {
                Text("\(model.sourceText.count.formatted()) characters")
                Spacer()
                Text("\(formatted(model.previewPlan.duration)) estimated")
            }
            .font(.system(size: 9, design: .monospaced))
            .foregroundStyle(TyperTheme.mutedStrong)
            .padding(.horizontal, 3).padding(.top, 9)

            VStack(spacing: 9) {
                HStack {
                    Text("Rhythm preview").font(.system(size: 11, weight: .medium))
                    Spacer()
                    Text("timing only · \(model.previewPlan.repairs) repair\(model.previewPlan.repairs == 1 ? "" : "s") from Mistake frequency")
                        .font(.system(size: 9, design: .monospaced)).foregroundStyle(TyperTheme.muted)
                }
                RhythmWaveform(plan: model.previewPlan)
                    .frame(height: 55)
                    .background(TyperTheme.surface)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
            .padding(.top, 18)
        }
    }

    private var controlRail: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Performance").font(.system(size: 12, weight: .semibold))
                Spacer()
                Text("\(humanScore)% human").font(.system(size: 9, weight: .medium, design: .monospaced)).foregroundStyle(TyperTheme.signal)
            }
            .frame(height: 54)

            controlGroup {
                Text("Mode").controlLabel()
                Picker("Mode", selection: $model.settings.mode) {
                    ForEach(TypingSettings.Mode.allCases) { mode in Text(mode.rawValue).tag(mode) }
                }
                .labelsHidden().pickerStyle(.segmented)
                Text(modeDescription).controlNote()
                HStack(spacing: 7) {
                    Circle().fill(model.isUsingLearnedProfile ? TyperTheme.signal : TyperTheme.muted).frame(width: 6, height: 6)
                    Text(model.performanceSourceTitle)
                    Spacer()
                    if !model.isUsingLearnedProfile {
                        Button("Train") { model.section = .train }.buttonStyle(QuietButtonStyle())
                    }
                }
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(model.isUsingLearnedProfile ? TyperTheme.signal : TyperTheme.mutedStrong)
            }

            controlGroup {
                controlHeader("Typing speed", value: "\(Int(model.settings.wpm)) WPM")
                Slider(value: $model.settings.wpm, in: 20...150, step: 1).tint(TyperTheme.primary)
                HStack { Text("20"); Spacer(); Text("150") }.rangeLabels()
            }

            controlGroup {
                controlHeader("Human variation", value: "\(Int(model.settings.variation * 100))%")
                Slider(value: $model.settings.variation, in: 0...1, step: 0.01).tint(TyperTheme.primary)
                Text("Shapes dwell, flight, bursts, and hesitation—not the final text.").controlNote()
            }

            controlGroup {
                controlHeader("Mistake frequency", value: mistakeLabel)
                Slider(value: Binding(get: { Double(model.settings.mistakeLevel) }, set: { model.settings.mistakeLevel = Int($0) }), in: 0...5, step: 1)
                    .tint(TyperTheme.primary).disabled(model.settings.mode == .clean)
                HStack { Text("Clean"); Spacer(); Text("Chaotic") }.rangeLabels()
            }

            VStack(spacing: 5) {
                compactToggle("Delayed repairs", note: "Notice errors a word or two later", binding: $model.settings.delayedRepairs)
                compactToggle("Thought pauses", note: "Occasional 2–5 second stalls", binding: $model.settings.thoughtPauses)
                compactToggle("Extended thought pauses", note: "Rare stalls can stretch up to 45 seconds", binding: $model.settings.extendedThoughtPauses)
                    .disabled(!model.settings.thoughtPauses)
                compactToggle("Fatigue drift", note: "Cadence evolves over long runs", binding: $model.settings.fatigueDrift)
            }
            .padding(.vertical, 10)

            Button(action: model.arm) {
                HStack {
                    Image(systemName: "play.fill").font(.system(size: 11))
                    Text("Arm typing")
                    Spacer()
                    Text("⌘↩").font(.system(size: 9, weight: .medium, design: .monospaced)).opacity(0.78)
                }
                .padding(.horizontal, 14)
            }
            .buttonStyle(PrimaryButtonStyle())
            .disabled(model.sourceText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || controller.state == .typing || controller.state == .preparing || isArmed)

            Text("After Arm: focus target  ·  Stop: ⌘ Esc / ⌃ Esc")
                .font(.system(size: 8.5, weight: .medium, design: .monospaced)).foregroundStyle(TyperTheme.muted).multilineTextAlignment(.center)
                .frame(maxWidth: .infinity).padding(.top, 9)
        }
    }

    private var isArmed: Bool { if case .armed = controller.state { return true }; return false }
    private var mistakeLabel: String { ["None", "Light", "Natural", "Frequent", "Messy", "Chaotic"][model.settings.mistakeLevel] }
    private var humanScore: Int { min(99, 72 + Int(model.settings.variation * 24) + min(3, model.playbackSettings.mistakeLevel) * 2) }
    private var modeDescription: String {
        switch model.settings.mode {
        case .personal: return profiles.profiles.isEmpty ? "Train a sample to unlock your personal fingerprint." : "Samples your measured timing and error signature."
        case .natural: return "Research-informed cadence with believable variation."
        case .clean: return "Human rhythm and pauses, with no injected typos."
        }
    }

    @ViewBuilder private func controlGroup<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10, content: content)
            .padding(.vertical, 11)
            .overlay(alignment: .bottom) { Rectangle().fill(TyperTheme.softLine).frame(height: 1) }
    }

    private func controlHeader(_ title: String, value: String) -> some View {
        HStack { Text(title).controlLabel(); Spacer(); Text(value).font(.system(size: 10, weight: .medium, design: .monospaced)) }
    }

    private func compactToggle(_ title: String, note: String, binding: Binding<Bool>) -> some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 10, weight: .medium))
                Text(note).font(.system(size: 8.5)).foregroundStyle(TyperTheme.muted)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Toggle("", isOn: binding)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.mini)
                .tint(TyperTheme.primary)
                .accessibilityLabel(Text(title))
                .accessibilityHint(Text(note))
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 3)
    }

    private func formatted(_ milliseconds: Double) -> String {
        let seconds = max(0, Int((milliseconds / 1_000).rounded()))
        return "\(seconds / 60):\(String(format: "%02d", seconds % 60))"
    }
}

private struct RhythmWaveform: View {
    let plan: TypingPlan
    var body: some View {
        GeometryReader { proxy in
            let count = max(1, min(88, Int(proxy.size.width / 7)))
            let step = max(1, plan.events.count / count)
            HStack(spacing: 3) {
                ForEach(0..<count, id: \.self) { index in
                    let eventIndex = min(max(0, plan.events.count - 1), index * step)
                    let event = plan.events.isEmpty ? nil : plan.events[eventIndex]
                    let isRepair = event?.kind == .backspace
                    let height = event.map { max(5, min(42, 45 - $0.flight / 36 + Double(index % 4) * 1.7)) } ?? 5
                    Capsule()
                        .fill(isRepair ? TyperTheme.signal : TyperTheme.primary)
                        .opacity(event?.flight ?? 0 > 500 ? 0.2 : isRepair ? 0.95 : 0.55)
                        .frame(maxWidth: 4, minHeight: CGFloat(height), maxHeight: CGFloat(height))
                }
            }
            .padding(.horizontal, 10)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

private extension Text {
    func controlLabel() -> some View { font(.system(size: 10, weight: .medium)).foregroundStyle(TyperTheme.ink) }
    func controlNote() -> some View { font(.system(size: 9)).foregroundStyle(TyperTheme.muted).lineSpacing(2) }
}

private extension View {
    func rangeLabels() -> some View { font(.system(size: 8, design: .monospaced)).foregroundStyle(TyperTheme.muted) }
}
