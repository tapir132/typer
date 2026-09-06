import SwiftUI

/// Native hover help, with a click/keyboard alternative that stays open.
struct HelpTip: View {
    let title: String
    let text: String
    @State private var isPresented = false

    var body: some View {
        Button { isPresented.toggle() } label: {
            Image(systemName: "questionmark.circle")
                .font(.system(size: 11, weight: .regular))
                .foregroundStyle(TyperTheme.mutedStrong)
                .frame(width: 18, height: 18)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(text)
        .accessibilityLabel("About \(title)")
        .accessibilityHint(text)
        .popover(isPresented: $isPresented, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 7) {
                Text(title).font(.system(size: 12, weight: .semibold))
                Text(text).font(.system(size: 12)).foregroundStyle(TyperTheme.mutedStrong)
                    .lineSpacing(3).fixedSize(horizontal: false, vertical: true)
            }
            .textSelection(.enabled)
            .padding(15).frame(width: 280, alignment: .leading)
            .foregroundStyle(TyperTheme.ink)
            .background(TyperTheme.surface)
        }
    }
}

enum QuickHelp {
    static let legacyProfile = "Available for playback, with its saved timing and correction habits. This Legacy profile cannot accept new samples or use the new validation system. New recordings train a separate My rhythm profile and leave this one unchanged."
    static let speed = "Target words per minute, using five characters per word. Pauses and repairs add time, so the finished run can average a slower pace."
    static let measuredSpeed = "Estimated pace of the recorded sample, expressed as five-character words per minute. Pauses and editing affect the measured pace."
    static let profileSpeed = "Estimated natural pace learned from this profile's samples. Baseline shows the selected generic speed. The Compose slider controls the playback target."
    static let variation = "How much key timing, bursts, and hesitation vary. This percentage is a setting, not a realism score. Mistake frequency controls errors separately."
    static let mistakes = "How often Typer generates an error and its correction. Clean mode disables generated mistakes. The preview shows the repair count for this text."
    static let dwell = "Time from pressing a key to releasing it, in milliseconds. This value summarizes key holds; a dash means no usable measurement yet."
    static let flight = "Time from releasing one key to pressing the next. A negative value means the two keys overlapped; a positive value means there was a gap."
    static let rollover = "Share of usable neighboring character pairs whose key presses overlap. Pairs with missing holds or a break in the sequence are excluded."
    static let mad = "Median absolute deviation of press intervals: the typical timing variation around the median. Larger values mean a wider spread."
    static let corrections = "Deletion actions relative to typed characters. Deletions can be corrections or revisions; this is not a count of all typing errors."
    static let detection = "How many characters were typed before correcting a known error. Requires a reference prompt; Freewrite and Live capture cannot establish your intended text."
    static let bursts = "Typical number of consecutive keys separated by less than 310 ms. That cutoff is a modeling choice used consistently in these measurements."
    static let trainingMode = "Copy follows a prompt, Freewrite captures new writing, Sprint captures faster typing, and Live capture records an opt-in session in another app. Save your in-app sample before switching."
    static let accessibility = "Required to send keys to another app. Enable Typer in macOS Privacy & Security → Accessibility. This permission does not start playback."
    static let inputMonitoring = "Only required for Live capture outside Typer. Recording starts when you click Start live capture and ends when you stop it, or after 15 minutes."
    static let checking = "Checks published builds at launch and every six hours while Typer is running. Check now checks immediately without restarting. Installing new app code requires a relaunch, which the update prompt can handle."
    static let installation = "Allows Sparkle to download and install verified updates automatically. Turn this off to review offered updates yourself. Automatic checking must also be enabled."
    static let channel = "Release follows versioned releases. Edge follows builds published after a successful push to main. A newer local build will not be replaced by an older published build."
    static let w1 = "Wasserstein distance: separation between two distributions in the feature's units. Lower is closer. Read it alongside sample counts and human-to-human variation."
    static let ks = "Largest cumulative difference between two distributions, from 0 to 1. Lower is closer. It is a descriptive distance, not a human probability or a significance test."
}
