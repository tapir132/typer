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
                            case .guide: AppGuideView(model: model)
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

            if controller.state == .typing {
                runningOverlay
                    .transition(.opacity)
            }

            if let toast = model.toast {
                VStack { Spacer(); Text(toast).font(.system(size: 12, weight: .medium)).foregroundStyle(TyperTheme.background).padding(.horizontal, 16).padding(.vertical, 11).background(TyperTheme.ink).clipShape(RoundedRectangle(cornerRadius: 8)).padding(.bottom, 22) }
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.easeOut(duration: 0.18), value: model.toast)
        .sheet(isPresented: $model.showsSystemSetup) { systemSetup }
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
                        model.showToast(liveCapture.canSave ? "Live capture stopped. Review and save the sample." : "Live capture stopped. At least 35 typed characters are needed.")
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
                Button { model.showsSystemSetup = true } label: { Image(systemName: "gearshape").font(.system(size: 13)) }
                    .buttonStyle(QuietButtonStyle())
                    .help("System setup, permissions, and updates")
                    .accessibilityLabel("System setup")
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
                Text("Typing in the active app").font(.system(size: 20, weight: .semibold))
                Text("Stop anytime with  ⌘ Esc  /  ⌃ Esc")
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                    .foregroundStyle(TyperTheme.mutedStrong)
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

    var systemSetup: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack {
                    VStack(alignment: .leading, spacing: 5) {
                        Text("System setup").font(.system(size: 20, weight: .semibold))
                        Text("Permissions for cross-app typing and optional Live capture.").font(.system(size: 12)).foregroundStyle(TyperTheme.mutedStrong)
                    }
                    Spacer()
                    Button("Done") { model.showsSystemSetup = false }.buttonStyle(QuietButtonStyle()).keyboardShortcut(.cancelAction)
                }
                HStack(spacing: 12) {
                    Image(systemName: model.accessibilityAuthorized ? "checkmark.shield.fill" : "exclamationmark.shield.fill")
                        .foregroundStyle(model.accessibilityAuthorized ? TyperTheme.signal : TyperTheme.danger)
                        .font(.system(size: 22))
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 4) {
                            Text("Accessibility permission").font(.system(size: 13, weight: .semibold))
                            HelpTip(title: "Accessibility permission", text: QuickHelp.accessibility)
                        }
                        Text(model.accessibilityAuthorized ? "Enabled" : "Required before the first run").font(.system(size: 11)).foregroundStyle(TyperTheme.mutedStrong)
                    }
                    Spacer()
                }
                .padding(15).typerSurface(radius: 10)
                HStack(spacing: 12) {
                    Image(systemName: model.inputMonitoringAuthorized ? "checkmark.shield.fill" : "waveform.badge.exclamationmark")
                        .foregroundStyle(model.inputMonitoringAuthorized ? TyperTheme.signal : TyperTheme.mutedStrong)
                        .font(.system(size: 22))
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 4) {
                            Text("Input Monitoring").font(.system(size: 13, weight: .semibold))
                            HelpTip(title: "Input Monitoring", text: QuickHelp.inputMonitoring)
                        }
                        Text(model.inputMonitoringAuthorized ? "Enabled for opt-in Live capture" : "Optional · required only for Live capture")
                            .font(.system(size: 11)).foregroundStyle(TyperTheme.mutedStrong)
                    }
                    Spacer()
                }
                .padding(15).typerSurface(radius: 10)
                HStack(spacing: 10) {
                    Button(model.accessibilityAuthorized ? "Permission enabled" : "Request permission") {
                        model.requestAccessibilityPermission()
                    }
                    .buttonStyle(SecondaryButtonStyle())
                    .disabled(model.accessibilityAuthorized)
                    Button("Open System Settings") { controller.openAccessibilitySettings() }.buttonStyle(SecondaryButtonStyle())
                }
                .frame(maxWidth: .infinity)
                HStack(spacing: 10) {
                    Button(model.inputMonitoringAuthorized ? "Input Monitoring enabled" : "Allow Live capture") {
                        model.requestInputMonitoringPermission()
                    }
                    .buttonStyle(SecondaryButtonStyle())
                    .disabled(model.inputMonitoringAuthorized)
                    Button("Open Input Monitoring") { model.openInputMonitoringSettings() }.buttonStyle(QuietButtonStyle())
                }
                Text("Accessibility lets Typer play keys. Input Monitoring is separate, optional, and only used during a Live capture session. All learned data stays on this Mac.")
                    .font(.system(size: 10)).foregroundStyle(TyperTheme.muted).lineSpacing(3)

                Rectangle().fill(TyperTheme.line).frame(height: 1).padding(.vertical, 2)

                Text("Updates").font(.system(size: 15, weight: .semibold))
                SettingsToggleRow(
                    title: "Check automatically",
                    detail: "Checks at launch and every six hours for published updates.",
                    explanation: QuickHelp.checking,
                    isOn: $updates.automaticallyChecks
                )
                SettingsToggleRow(
                    title: "Install automatically",
                    detail: "Downloads and installs verified updates when available.",
                    explanation: QuickHelp.installation,
                    isEnabled: updates.automaticallyChecks,
                    isOn: $updates.automaticallyDownloads
                )

                HStack {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Typer \(updates.build.version)")
                            .font(.system(size: 12, weight: .semibold))
                        Text(updates.build.originLabel)
                            .font(.system(size: 10)).foregroundStyle(TyperTheme.mutedStrong)
                        if let builtAt = updates.build.builtAt {
                            Text("Built \(builtAt.formatted(date: .abbreviated, time: .shortened))")
                                .font(.system(size: 9)).foregroundStyle(TyperTheme.muted)
                        }
                    }
                    Spacer()
                    Button(updates.checkSummary.isChecking ? "Checking…" : "Check now") { updates.checkForUpdates() }.buttonStyle(SecondaryButtonStyle()).disabled(!updates.canCheckForUpdates)
                }

                HStack(spacing: 4) {
                    Text("Update channel").font(.system(size: 11, weight: .medium))
                    HelpTip(title: "Update channel", text: QuickHelp.channel)
                }
                Picker("Update channel", selection: $updates.channel) {
                    ForEach(UpdateChannel.allCases) { channel in Text(channel.title).tag(channel) }
                }
                .pickerStyle(.segmented).labelsHidden()
                .disabled(updates.checkSummary.isChecking)

                Text("Check now works while Typer is open. Installing new app code requires a relaunch; the update prompt can handle that for you.")
                    .font(.system(size: 11)).foregroundStyle(TyperTheme.mutedStrong)
                    .fixedSize(horizontal: false, vertical: true)

                Text(updates.build.isLocal
                     ? "This app was built on this Mac. Local edits appear after rebuilding and relaunching Typer; the updater checks published builds only."
                     : updates.channel == .stable ? "Release delivers tested, versioned releases." : "Edge delivers builds published after a successful push to main.")
                    .font(.system(size: 11)).foregroundStyle(TyperTheme.mutedStrong).fixedSize(horizontal: false, vertical: true)

                if let message = updates.checkSummary.message, updates.lastError == nil {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(message).font(.system(size: 11, weight: .medium))
                        if let version = updates.checkSummary.publishedVersion {
                            Text("Latest published: \(version)").font(.system(size: 10)).foregroundStyle(TyperTheme.mutedStrong)
                        }
                        if let checkedAt = updates.checkSummary.checkedAt {
                            Text("Last checked \(checkedAt.formatted(date: .abbreviated, time: .shortened))")
                                .font(.system(size: 10)).foregroundStyle(TyperTheme.muted)
                        }
                    }
                }

                if let updateError = updates.lastError {
                    Text("Update failed: \(updateError)")
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(TyperTheme.danger)
                        .textSelection(.enabled)
                        .lineLimit(4)
                }
            }
            .padding(26)
        }
        .frame(width: 500, height: min(780, (NSScreen.main?.visibleFrame.height ?? 860) - 80))
        .background(TyperTheme.background)
        .task {
            while !Task.isCancelled {
                model.refreshPermissions()
                try? await Task.sleep(for: .seconds(1))
            }
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

struct SettingsToggleRow: View {
    let title: String
    let detail: String
    let explanation: String
    var isEnabled = true
    @Binding var isOn: Bool

    var body: some View {
        HStack(alignment: .center, spacing: 18) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 4) {
                    Text(title).font(.system(size: 12, weight: .semibold))
                    HelpTip(title: title, text: explanation)
                }
                Text(detail).font(.system(size: 10)).foregroundStyle(TyperTheme.mutedStrong)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Toggle(title, isOn: $isOn)
                .labelsHidden().toggleStyle(.switch).controlSize(.small).tint(TyperTheme.primary)
                .disabled(!isEnabled)
                .fixedSize()
                .accessibilityLabel(title)
                .help(detail)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
