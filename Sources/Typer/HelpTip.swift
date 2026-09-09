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
    static let sentencePauses = "Waits after each sentence when more text follows. Choose a random range, or equal Min and Max for a fixed wait. Works in Clean too; overlapping pauses use the longer wait."
    static let legacyProfile = "Still usable for playback. Training and validation are locked; new samples build My rhythm separately. You can keep this profile."
    static let speed = "Target pace in five-character words per minute. Pauses and repairs make the finished run slower."
    static let measuredSpeed = "Recorded pace in five-character words per minute, including pauses and editing. Idle gaps lower this number."
    static let activeSpeed = "Pace during continuous typing, including deletions. Gaps over 2.5 seconds and activity breaks are excluded. The session timer includes all elapsed time; other live timing measurements show recent keys."
    static let profileSpeed = "Pace learned from this profile's samples. The Compose speed slider sets your playback target."
    static let variation = "Changes the spread in timing and hesitation. This is a setting, not a realism score; mistakes have their own control."
    static let mistakes = "How often Typer makes and repairs errors. Clean disables them; the preview shows the planned repair count."
    static let dwell = "How long a key is held down, in milliseconds. A dash means no usable measurement yet."
    static let flight = "Time from releasing one key to pressing the next. Negative means overlap; positive means a gap."
    static let rollover = "Share of neighboring key pairs that overlap. Only pairs with usable key-release timing are counted."
    static let mad = "Typical variation in the time between presses. A larger value means a wider spread in timing."
    static let corrections = "Deletion actions per typed character. Includes both typo corrections and changes of mind."
    static let detection = "Characters typed past an error before correcting it. Requires a reference passage, so it's unavailable for Freewrite and Live capture."
    static let bursts = "Typical number of keys typed in quick succession, with less than 310 ms between presses."
    static let trainingMode = "Copy or Sprint follows a passage. Freewrite captures new writing. Live capture records outside Typer. Save your exercise before switching."
    static let liveCaptureGaps = "Gaps over 2.5 seconds, app switches, and clicks break the typing sequence. Idle time doesn't lower active speed. Live capture skips thinking pauses; use Freewrite to learn those."
    static let accessibility = "Allows typing into another app. Enable Typer in macOS Privacy & Security → Accessibility. Granting permission doesn't start typing."
    static let inputMonitoring = "Only needed for Live capture. Recording starts when you choose Start live capture, and stops manually or after one hour."
    static let checking = "Checks at launch and every six hours. Check now works without restarting; installing an update relaunches Typer."
    static let installation = "Downloads and installs verified updates automatically. Turn off to review updates yourself. Requires automatic checking."
    static let channel = "Release gets versioned releases. Edge gets the latest successful build from main. Older builds won't replace newer ones."
    static let w1 = "Distance between two distributions in the measurement's units. Lower is closer; compare sample counts and human-to-human variation too."
    static let ks = "Distribution distance from 0–1. Lower is closer. It isn't a probability that typing is human."
}
