import SwiftUI

struct RootView: View {
    @ObservedObject var model: AppModel
    @ObservedObject private var controller: TypingController
    @ObservedObject private var profiles: ProfileStore
    @ObservedObject private var liveCapture: GlobalTrainingCapture
    @ObservedObject private var updates = UpdateManager.shared

    // Optional geometry observation supports native window layout regression checks.
    var onHeaderFrameChange: ((CGRect) -> Void)?

    init(model: AppModel, onHeaderFrameChange: ((CGRect) -> Void)? = nil) {
        self.onHeaderFrameChange = onHeaderFrameChange
        self.model = model
        controller = model.controller
        profiles = model.profiles
        liveCapture = model.liveCapture
    }

    var body: some View {
        ZStack {
            TyperTheme.background.ignoresSafeArea()
            GeometryReader { window in
                VStack(spacing: 0) {
                    topBar
                        .fixedSize(horizontal: false, vertical: true)
                    ScrollView {
                        Group {
                            switch model.section {
                            case .compose: ComposeView(model: model)
                            case .train: TrainingView(model: model)
                            case .profiles: ProfilesView(model: model)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                        .frame(minHeight: max(0, window.size.height - TyperLayout.topBarHeight), alignment: .topLeading)
                    }
                    .id(model.section)
                    .scrollBounceBehavior(.basedOnSize)
                    .frame(height: max(0, window.size.height - TyperLayout.topBarHeight))
                }
                .frame(width: window.size.width, height: window.size.height, alignment: .top)
            }

            if case .armed(let count) = controller.state {
                countdownOverlay(count)
                    .transition(.opacity.combined(with: .scale(scale: 0.98)))
            }

            if controller.state.isPlaybackActive {
                runningOverlay
                    .transition(.opacity)
            }

            if let toast = model.toast {
                VStack { Spacer(); Text(toast).font(.system(size: 12, weight: .medium)).foregroundStyle(TyperTheme.background).padding(.horizontal, 16).padding(.vertical, 11).background(TyperTheme.ink).clipShape(RoundedRectangle(cornerRadius: 8)).padding(.bottom, 22) }
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.easeOut(duration: 0.18), value: model.toast)
        .sheet(isPresented: $model.showsSettings) { SettingsView(model: model) }
        .onReceive(NotificationCenter.default.publisher(for: .typerWillQuit)) { _ in
            model.showsSettings = false
            model.controller.stop()
        }
        .onAppear { updates.start() }
        .onChange(of: controller.state) { _, state in
            switch state {
            case .complete:
                model.showToast("Typing complete.")
                Task { try? await Task.sleep(for: .seconds(1.8)); controller.reset() }
            case .stopped:
                model.showToast("Typing stopped.")
                Task { try? await Task.sleep(for: .seconds(1.4)); controller.reset() }
            case .error(let message): model.showToast(message)
            default: break
            }
        }
    }

    private var topBar: some View {
        HStack(spacing: 0) {
            HStack(spacing: 10) {
                RhythmMark()
                Text("Typer").font(.system(size: 15, weight: .semibold))
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: 0) {
                ForEach(AppSection.allCases) { section in
                    Button { model.section = section } label: {
                        Text(section.rawValue)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(model.section == section ? TyperTheme.ink : TyperTheme.muted)
                            .frame(width: TyperLayout.navigationTabWidth, height: TyperLayout.topBarHeight)
                            .contentShape(Rectangle())
                            .overlay(alignment: .bottom) {
                                if model.section == section {
                                    Rectangle().fill(TyperTheme.signal).frame(width: 30, height: 2)
                                }
                            }
                    }
                    .buttonStyle(.plain)
                }
            }

            HStack(spacing: 9) {
                if liveCapture.isCapturing {
                    Button {
                        liveCapture.stop()
                        model.trainingMode = .liveCapture
                        model.section = .train
                        model.showToast(liveCapture.canSave ? "Live capture stopped. Review and save the sample." : "Live capture stopped. \(liveCapture.saveRequirement)")
                    } label: {
                        HStack(spacing: 6) {
                            Circle().fill(TyperTheme.danger).frame(width: 7, height: 7)
                            Text("Stop capture").font(.system(size: 10, weight: .semibold, design: .monospaced)).foregroundStyle(TyperTheme.danger)
                        }
                        .frame(minHeight: 40)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("Stop the opt-in global training session")
                } else {
                    Circle().fill(statusColor).frame(width: 7, height: 7)
                    Text(controller.state.label).font(.system(size: 11, weight: .medium, design: .monospaced)).foregroundStyle(TyperTheme.mutedStrong)
                }
                Button { model.showSettings() } label: { Image(systemName: "gearshape").font(.system(size: 13)) }
                    .buttonStyle(QuietButtonStyle())
                    .help("Settings, guide, permissions, and updates")
                    .accessibilityLabel("Settings")
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .padding(.leading, 78)
        .padding(.trailing, 16)
        .frame(height: TyperLayout.topBarHeight)
        .background {
            if let onHeaderFrameChange {
                GeometryReader { geometry in
                    let frame = geometry.frame(in: .global)
                    Color.clear.onAppear { onHeaderFrameChange(frame) }
                        .onChange(of: frame) { _, value in onHeaderFrameChange(value) }
                }
            }
        }
        .background(TyperTheme.chrome)
        .overlay(alignment: .bottom) { Rectangle().fill(TyperTheme.softLine).frame(height: 1) }
    }

    private var statusColor: Color {
        if case .error = controller.state { return TyperTheme.danger }
        return TyperTheme.signal
    }

    private func countdownOverlay(_ count: Int) -> some View {
        ZStack {
            Color.black.opacity(0.72).ignoresSafeArea()
            VStack(spacing: 13) {
                ZStack {
                    Circle().stroke(TyperTheme.primary.opacity(0.22), lineWidth: 8)
                    Circle().trim(from: 0, to: CGFloat(count) / 5).stroke(TyperTheme.primary, style: StrokeStyle(lineWidth: 3, lineCap: .round)).rotationEffect(.degrees(-90))
                    Text("\(count)").font(.system(size: 34, weight: .semibold, design: .monospaced))
                }
                .frame(width: 86, height: 86)
                Text("Click where you want me to type.").font(.system(size: 20, weight: .semibold))
                Text("Typer begins when the countdown ends.").font(.system(size: 12)).foregroundStyle(TyperTheme.mutedStrong)
                Button("Cancel") { controller.stop() }.buttonStyle(QuietButtonStyle()).padding(.top, 5)
            }
            .padding(34)
            .frame(width: 430)
            .background(TyperTheme.surface)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
    }

    private var runningOverlay: some View {
        ZStack {
            Color.black.opacity(0.76).ignoresSafeArea()
            VStack(spacing: 14) {
                Image(systemName: "keyboard.fill")
                    .font(.system(size: 28, weight: .medium))
                    .foregroundStyle(TyperTheme.signal)
                Text(controller.state == .paused ? "Typing is paused" : controller.progress.activity).font(.system(size: 20, weight: .semibold))
                Text(controller.pauseMessage ?? "⌘⌥P pause/resume · ⌘ Esc / ⌃ Esc stop")
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                    .foregroundStyle(TyperTheme.mutedStrong)
                if controller.state == .paused {
                    Button("Return to target app") { controller.focusTarget() }.buttonStyle(SecondaryButtonStyle())
                    Text("Focus the same field, then press ⌘⌥P.").font(.caption).foregroundStyle(TyperTheme.mutedStrong)
                } else {
                    Button("Pause typing") { controller.pause() }.buttonStyle(SecondaryButtonStyle())
                    Button("Skip current wait") { controller.skipWait() }.buttonStyle(QuietButtonStyle())
                        .disabled(!controller.progress.canSkipWait)
                }
                Button("Stop typing") { controller.stop() }
                    .buttonStyle(SecondaryButtonStyle())
                    .padding(.top, 4)
            }
            .padding(32)
            .frame(width: 390)
            .background(TyperTheme.surface)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
    }
}

private struct RhythmMark: View {
    var body: some View {
        HStack(alignment: .bottom, spacing: 2) {
            Capsule().fill(TyperTheme.primary).frame(width: 4, height: 9)
            Capsule().fill(TyperTheme.signal).frame(width: 4, height: 18)
            Capsule().fill(TyperTheme.primary).frame(width: 4, height: 13)
        }
        .frame(width: 18, height: 20)
    }
}
