import SwiftUI

struct ProfilesView: View {
    @ObservedObject var model: AppModel
    @ObservedObject private var profiles: ProfileStore

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
                Button("Train another sample") { model.section = .train }.buttonStyle(SecondaryButtonStyle())
            }
            .padding(.bottom, 28)

            VStack(spacing: 0) {
                profileRow(.baseline(wpm: model.settings.wpm))
                ForEach(profiles.profiles) { profile in profileRow(profile) }
            }
            .overlay(alignment: .top) { Rectangle().fill(TyperTheme.line).frame(height: 1) }
            Spacer()
        }
        .padding(.horizontal, 48)
        .padding(.top, 34)
        .padding(.bottom, 34)
    }

    private func profileRow(_ profile: TypingProfile) -> some View {
        let active = profiles.activeProfileID == profile.id
        return HStack(spacing: 18) {
            HStack(spacing: 13) {
                Text(initials(profile.name)).font(.system(size: 10, weight: .bold, design: .monospaced)).foregroundStyle(TyperTheme.signal)
                    .frame(width: 38, height: 38).background(TyperTheme.raised).clipShape(RoundedRectangle(cornerRadius: 9))
                VStack(alignment: .leading, spacing: 4) {
                    Text(profile.name).font(.system(size: 12, weight: .semibold))
                    Text(profile.sampleCount == 0 ? "Built-in research baseline" : "\(profile.sampleCount) learned sample\(profile.sampleCount == 1 ? "" : "s")")
                        .font(.system(size: 9)).foregroundStyle(TyperTheme.muted)
                }
            }
            .frame(minWidth: 190, alignment: .leading)

            ProfileStat(value: "\(Int(profile.wpm.rounded())) WPM", label: "natural speed")
            ProfileStat(value: "\(Int(profile.dwellMedian.rounded())) ms", label: "key dwell")
            ProfileStat(value: "\(Int(max(0, profile.medianInterval - profile.dwellMedian).rounded())) ms", label: "flight time")
            ProfileStat(value: "±\(Int(profile.intervalMAD.rounded())) ms", label: "timing jitter")
            ProfileStat(value: "\(Int((profile.backspaceRate * 100).rounded()))%", label: "corrections")
            Spacer()
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
        .padding(.vertical, 21)
        .padding(.horizontal, 10)
        .background(active ? TyperTheme.primary.opacity(0.055) : .clear)
        .overlay(alignment: .bottom) { Rectangle().fill(TyperTheme.softLine).frame(height: 1) }
    }

    private func initials(_ name: String) -> String { name.split(separator: " ").prefix(2).compactMap(\.first).map(String.init).joined().uppercased() }
}

private struct ProfileStat: View {
    let value: String
    let label: String
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(value).font(.system(size: 10, weight: .medium, design: .monospaced))
            Text(label).font(.system(size: 8.5)).foregroundStyle(TyperTheme.muted)
        }
        .frame(minWidth: 64, alignment: .leading)
    }
}
