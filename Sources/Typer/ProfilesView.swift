import SwiftUI

struct ProfilesView: View {
    @ObservedObject var model: AppModel
    @ObservedObject private var profiles: ProfileStore
    @State private var showsValidation = false

    init(model: AppModel) {
        self.model = model
        profiles = model.profiles
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 7) {
                    Text("Typing fingerprints.").font(.system(size: 27, weight: .semibold)).tracking(-0.5)
                    Text("Each profile carries its own dwell, flight, cadence, error habits, and correction reflexes.").font(.system(size: 13)).foregroundStyle(TyperTheme.mutedStrong)
                }
                Spacer()
                Button("Validate rhythm") { showsValidation = true }.buttonStyle(SecondaryButtonStyle())
                    .help("Validates current samples. Legacy profiles are playback-only.")
                Button("Train My rhythm") { model.section = .train }.buttonStyle(SecondaryButtonStyle())
            }
            .padding(.bottom, 28)

            if !profiles.samples.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 5) {
                        Text("\(profiles.samples.count) saved samples total · \(profiles.activeProfile.sampleCount) used by active profile")
                            .font(.system(size: 11, weight: .medium))
                        HelpTip(title: "Saved samples and profile training", text: profiles.sampleUsageExplanation)
                    }
                    if let note = profiles.unusedOlderSamplesNote {
                        Text(note).font(.system(size: 11)).foregroundStyle(TyperTheme.mutedStrong)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(.bottom, 18)
            }

            VStack(spacing: 0) {
                profileRow(.baseline(wpm: model.settings.wpm))
                ForEach(profiles.profiles) { profile in profileRow(profile) }
            }
            .overlay(alignment: .top) { Rectangle().fill(TyperTheme.line).frame(height: 1) }
            Button { model.showGuide(.measurements) } label: {
                Label("Understand these measurements and validate a profile", systemImage: "questionmark.circle")
            }
            .buttonStyle(QuietButtonStyle()).padding(.top, 14)
            if !profiles.samples.isEmpty || !profiles.profiles.isEmpty {
                Button("Delete all learned data", role: .destructive) { profiles.deleteAllLearnedData() }
                    .buttonStyle(QuietButtonStyle()).padding(.top, 18)
            }
            Spacer()
        }
        .sheet(isPresented: $showsValidation) { ValidationView(samples: profiles.samples.filter { !$0.isLegacy }) }
        .padding(.horizontal, TyperLayout.workspaceHorizontalPadding)
        .padding(.top, TyperLayout.workspaceTopPadding)
        .padding(.bottom, TyperLayout.workspaceBottomPadding)
    }

    private func profileRow(_ profile: TypingProfile) -> some View {
        let active = profiles.activeProfileID == profile.id
        return VStack(alignment: .leading, spacing: 14) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 18) {
                    profileIdentity(profile)
                    profileStatistics(profile)
                    Spacer(minLength: 0)
                    profileActions(profile)
                }
                VStack(alignment: .leading, spacing: 18) {
                    HStack {
                        profileIdentity(profile)
                        Spacer()
                        profileActions(profile)
                    }
                    HStack(spacing: 20) {
                        profileStatistics(profile)
                        Spacer(minLength: 0)
                    }
                }
            }
            if profile.isLegacy {
                VStack(alignment: .leading, spacing: 7) {
                    HStack(spacing: 4) {
                        Label("Legacy profile · training locked", systemImage: "lock.fill")
                            .font(.system(size: 11, weight: .semibold))
                        HelpTip(title: "Legacy profile", text: QuickHelp.legacyProfile)
                    }
                    Text(QuickHelp.legacyProfile)
                        .font(.system(size: 11)).foregroundStyle(TyperTheme.mutedStrong)
                        .lineSpacing(3).fixedSize(horizontal: false, vertical: true)
                }
                .padding(.top, 3)
            }
        }
        .padding(.vertical, 21)
        .padding(.horizontal, 10)
        .background(active ? TyperTheme.primary.opacity(0.055) : .clear)
        .overlay(alignment: .bottom) { Rectangle().fill(TyperTheme.softLine).frame(height: 1) }
    }

    private func profileIdentity(_ profile: TypingProfile) -> some View {
        HStack(spacing: 13) {
            Text(initials(profile.name)).font(.system(size: 10, weight: .bold, design: .monospaced)).foregroundStyle(TyperTheme.signal)
                .frame(width: 38, height: 38).background(TyperTheme.raised).clipShape(RoundedRectangle(cornerRadius: 9))
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 7) {
                    Text(profile.name).font(.system(size: 12, weight: .semibold))
                    if profile.isLegacy {
                        Text("Legacy").font(.system(size: 9, weight: .medium))
                            .foregroundStyle(TyperTheme.mutedStrong)
                            .padding(.horizontal, 6).padding(.vertical, 3)
                            .background(TyperTheme.raised).clipShape(RoundedRectangle(cornerRadius: 4))
                    }
                }
                Text(profile.sampleCount == 0 ? "Built-in research baseline" : "Trained on \(profile.sampleCount) sample\(profile.sampleCount == 1 ? "" : "s")")
                    .font(.system(size: 9)).foregroundStyle(TyperTheme.muted)
            }
        }
        .frame(minWidth: 190, alignment: .leading)
        .fixedSize(horizontal: true, vertical: false)
    }

    @ViewBuilder private func profileStatistics(_ profile: TypingProfile) -> some View {
        ProfileStat(value: "\(Int(profile.wpm.rounded())) WPM", label: "natural speed", help: QuickHelp.profileSpeed)
        ProfileStat(value: "\(Int(profile.dwellMedian.rounded())) ms", label: "key dwell", help: QuickHelp.dwell)
        ProfileStat(value: profile.evidence?.rolloverRate.map { "\(Int(($0 * 100).rounded()))%" } ?? "—", label: "rollover", help: QuickHelp.rollover)
        ProfileStat(value: "±\(Int(profile.intervalMAD.rounded())) ms", label: "interval MAD", help: QuickHelp.mad)
        ProfileStat(value: "\(Int((profile.backspaceRate * 100).rounded()))%", label: "corrections", help: QuickHelp.corrections)
    }

    private func profileActions(_ profile: TypingProfile) -> some View {
        let active = profiles.activeProfileID == profile.id
        return HStack(spacing: 8) {
            Button(active ? "Active" : "Use profile") {
                profiles.use(profile)
                model.settings.mode = profile.id == TypingProfile.baselineID ? .natural : .personal
                model.showToast("\(profile.name) is now active.")
            }
            .buttonStyle(SecondaryButtonStyle()).disabled(active)

            if profile.id != TypingProfile.baselineID {
                Button(role: .destructive) { profiles.remove(profile) } label: { Image(systemName: "trash") }
                    .buttonStyle(QuietButtonStyle()).help("Delete profile")
            }
        }
        .fixedSize()
    }

    private func initials(_ name: String) -> String { name.split(separator: " ").prefix(2).compactMap(\.first).map(String.init).joined().uppercased() }
}

private struct ProfileStat: View {
    let value: String
    let label: String
    let help: String
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(value).font(.system(size: 10, weight: .medium, design: .monospaced))
            HStack(spacing: 2) {
                Text(label).font(.system(size: 8.5)).foregroundStyle(TyperTheme.muted)
                HelpTip(title: label, text: help)
            }
        }
        .frame(minWidth: 64, alignment: .leading)
        .fixedSize(horizontal: true, vertical: false)
    }
}
