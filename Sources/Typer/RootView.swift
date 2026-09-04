import SwiftUI

struct RootView: View {
    @ObservedObject var model: AppModel
    @ObservedObject private var controller: TypingController
    @ObservedObject private var profiles: ProfileStore
    @ObservedObject private var updates = UpdateManager.shared

    init(model: AppModel) {
        self.model = model
        controller = model.controller
        profiles = model.profiles
    }

    var body: some View {
        ZStack {
            TyperTheme.background.ignoresSafeArea()
            VStack(spacing: 0) {
                topBar
                Group {
                    switch model.section {
                    case .compose: ComposeView(model: model)
                    case .train: TrainingView(model: model)
                    case .profiles: ProfilesView(model: model)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            if case .armed(let count) = controller.state {
                countdownOverlay(count)
                    .transition(.opacity.combined(with: .scale(scale: 0.98)))
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
                Circle().fill(statusColor).frame(width: 7, height: 7)
                Text(controller.state.label).font(.system(size: 11, weight: .medium, design: .monospaced)).foregroundStyle(TyperTheme.mutedStrong)
                Button { model.showsSystemSetup = true } label: { Image(systemName: "gearshape").font(.system(size: 13)) }
                    .buttonStyle(QuietButtonStyle())
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .padding(.leading, 78)
        .padding(.trailing, 16)
        .frame(height: TyperLayout.topBarHeight)
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

    private var systemSetup: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack {
                VStack(alignment: .leading, spacing: 5) {
                    Text("System setup").font(.system(size: 20, weight: .semibold))
                    Text("One permission enables native cross-app typing.").font(.system(size: 12)).foregroundStyle(TyperTheme.mutedStrong)
                }
                Spacer()
                Button("Done") { model.showsSystemSetup = false }.buttonStyle(QuietButtonStyle())
            }
            HStack(spacing: 12) {
                Image(systemName: model.accessibilityAuthorized ? "checkmark.shield.fill" : "exclamationmark.shield.fill")
                    .foregroundStyle(model.accessibilityAuthorized ? TyperTheme.signal : TyperTheme.danger)
                    .font(.system(size: 22))
                VStack(alignment: .leading, spacing: 4) {
                    Text("Accessibility permission").font(.system(size: 13, weight: .semibold))
                    Text(model.accessibilityAuthorized ? "Enabled" : "Required before the first run").font(.system(size: 11)).foregroundStyle(TyperTheme.mutedStrong)
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
            Text("In Privacy & Security → Accessibility, enable Typer. Your source text and learned profile stay on this Mac.")
                .font(.system(size: 10)).foregroundStyle(TyperTheme.muted).lineSpacing(3)

            Rectangle().fill(TyperTheme.line).frame(height: 1).padding(.vertical, 2)

            Text("Updates").font(.system(size: 15, weight: .semibold))
            Toggle(isOn: $updates.automaticallyChecks) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Check automatically").font(.system(size: 12, weight: .semibold))
                    Text("Checks at launch and every six hours, then prompts for signed releases.").font(.system(size: 9)).foregroundStyle(TyperTheme.muted)
                }
            }
            .toggleStyle(.switch).controlSize(.small).tint(TyperTheme.primary)

            Toggle(isOn: $updates.automaticallyDownloads) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Install automatically").font(.system(size: 12, weight: .semibold))
                    Text("Sparkle verifies the Ed25519 signature before replacing Typer.").font(.system(size: 9)).foregroundStyle(TyperTheme.muted)
                }
            }
            .toggleStyle(.switch).controlSize(.small).tint(TyperTheme.primary).disabled(!updates.automaticallyChecks)

            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Typer \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "Development")")
                        .font(.system(size: 12, weight: .semibold))
                    Text(updates.channel == .stable ? "Tested, versioned releases" : "Every successful main build")
                        .font(.system(size: 9)).foregroundStyle(TyperTheme.muted)
                }
                Spacer()
                Button("Check now") { updates.checkForUpdates() }.buttonStyle(SecondaryButtonStyle()).disabled(!updates.canCheckForUpdates)
            }

            Picker("Update channel", selection: $updates.channel) {
                ForEach(UpdateChannel.allCases) { channel in Text(channel.title).tag(channel) }
            }
            .pickerStyle(.segmented).labelsHidden()

            if let updateError = updates.lastError {
                Text("Last update error: \(updateError)")
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(TyperTheme.danger)
                    .textSelection(.enabled)
                    .lineLimit(4)
            }
        }
        .padding(26)
        .frame(width: 500)
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
