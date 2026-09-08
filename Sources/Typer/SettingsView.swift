import SwiftUI

struct SettingsView: View {
    @ObservedObject var model: AppModel
    @ObservedObject private var updates = UpdateManager.shared

    static var height: CGFloat { min(740, (NSScreen.main?.visibleFrame.height ?? 820) - 80) }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Settings").font(.system(size: 20, weight: .semibold))
                Spacer()
                Button("Done") { model.showsSettings = false }
                    .buttonStyle(QuietButtonStyle()).keyboardShortcut(.cancelAction)
            }
            .padding(.horizontal, 26).padding(.top, 20).padding(.bottom, 16)

            Picker("Settings section", selection: $model.settingsSection) {
                ForEach(SettingsSection.allCases) { section in Text(section.rawValue).tag(section) }
            }
            .pickerStyle(.segmented).labelsHidden().frame(width: 240).padding(.bottom, 20)

            Rectangle().fill(TyperTheme.line).frame(height: 1)
            Group {
                switch model.settingsSection {
                case .general: general
                case .guide: AppGuideView(model: model)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .frame(width: 800, height: Self.height)
        .foregroundStyle(TyperTheme.ink)
        .background(TyperTheme.background)
        .task {
            while !Task.isCancelled {
                model.refreshPermissions()
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    private var general: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text("Permissions").font(.system(size: 15, weight: .semibold))
                HStack(spacing: 12) {
                    Image(systemName: model.accessibilityAuthorized ? "checkmark.shield.fill" : "exclamationmark.shield.fill")
                        .foregroundStyle(model.accessibilityAuthorized ? TyperTheme.signal : TyperTheme.danger)
                        .font(.system(size: 22))
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 4) {
                            Text("Accessibility").font(.system(size: 13, weight: .semibold))
                            HelpTip(title: "Accessibility", text: QuickHelp.accessibility)
                        }
                        Text(model.accessibilityAuthorized ? "Enabled" : "Required for typing into other apps").font(.system(size: 11)).foregroundStyle(TyperTheme.mutedStrong)
                    }
                    Spacer()
                    if !model.accessibilityAuthorized {
                        Button("Enable") { model.requestAccessibilityPermission() }.buttonStyle(SecondaryButtonStyle())
                    }
                    Button("Open settings") { model.controller.openAccessibilitySettings() }
                        .buttonStyle(QuietButtonStyle()).accessibilityLabel("Open Accessibility settings")
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
                        Text(model.inputMonitoringAuthorized ? "Enabled for opt-in Live capture" : "Optional · for Live capture only")
                            .font(.system(size: 11)).foregroundStyle(TyperTheme.mutedStrong)
                    }
                    Spacer()
                    if !model.inputMonitoringAuthorized {
                        Button("Enable") { model.requestInputMonitoringPermission() }.buttonStyle(SecondaryButtonStyle())
                    }
                    Button("Open settings") { model.openInputMonitoringSettings() }
                        .buttonStyle(QuietButtonStyle()).accessibilityLabel("Open Input Monitoring settings")
                }
                .padding(15).typerSurface(radius: 10)
                Text("Permissions never start typing or recording on their own.")
                    .font(.system(size: 10)).foregroundStyle(TyperTheme.muted).lineSpacing(3)

                Rectangle().fill(TyperTheme.line).frame(height: 1).padding(.vertical, 2)

                Text("Updates").font(.system(size: 15, weight: .semibold))
                SettingsToggleRow(
                    title: "Check automatically",
                    detail: "At launch and every six hours.",
                    explanation: QuickHelp.checking,
                    isOn: $updates.automaticallyChecks
                )
                SettingsToggleRow(
                    title: "Install automatically",
                    detail: "Let Typer install verified updates.",
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

                Text("No restart needed to check. Installing an update relaunches Typer.")
                    .font(.system(size: 11)).foregroundStyle(TyperTheme.mutedStrong)
                    .fixedSize(horizontal: false, vertical: true)

                Text(updates.build.isLocal
                     ? "Local build: rebuild and reopen Typer to use unpublished changes."
                     : updates.channel == .stable ? "Release: versioned releases." : "Edge: the latest successful build from main.")
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
            .frame(maxWidth: 580, alignment: .leading)
            .padding(26)
            .frame(maxWidth: .infinity)
        }
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
