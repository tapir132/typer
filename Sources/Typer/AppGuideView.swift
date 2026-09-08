import SwiftUI

enum GuideTopic: String, CaseIterable, Identifiable {
    case firstRun = "Start typing"
    case controls = "Modes & pauses"
    case training = "Training & profiles"
    case measurements = "Measurements"
    case validation = "Validation"
    case privacy = "Privacy & permissions"
    case updates = "Updates"
    case troubleshooting = "Troubleshooting"

    var id: String { rawValue }
}

struct AppGuideView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(GuideTopic.allCases) { topic in
                        Button { model.guideTopic = topic } label: {
                            Text(topic.rawValue)
                                .font(.system(size: 12, weight: model.guideTopic == topic ? .semibold : .regular))
                                .foregroundStyle(model.guideTopic == topic ? TyperTheme.signal : TyperTheme.mutedStrong)
                                .frame(maxWidth: .infinity, minHeight: 36, alignment: .leading)
                                .padding(.horizontal, 10)
                                .background(model.guideTopic == topic ? TyperTheme.surface : .clear)
                                .clipShape(RoundedRectangle(cornerRadius: 7))
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityAddTraits(model.guideTopic == topic ? .isSelected : [])
                    }
                    Rectangle().fill(TyperTheme.line).frame(height: 1).padding(.vertical, 14)
                    VStack(alignment: .leading, spacing: 9) {
                        shortcut("⌘⌥P", "Pause / resume")
                        shortcut("⌘⌥→", "Skip a long wait")
                        shortcut("⌘ Esc / ⌃ Esc", "Stop typing")
                    }
                    .padding(.horizontal, 10)
                }
                .padding(.vertical, 20).padding(.horizontal, 14)
            }
            .frame(width: 204)
            Rectangle().fill(TyperTheme.line).frame(width: 1)
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    Text(model.guideTopic.rawValue).font(.system(size: 21, weight: .semibold))
                        .accessibilityAddTraits(.isHeader)
                    topicContent
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
                .padding(26)
            }
            // Each topic starts at its first instruction and closes any expanded details.
            .id(model.guideTopic)
        }
        .foregroundStyle(TyperTheme.ink)
    }

    @ViewBuilder private var topicContent: some View {
        switch model.guideTopic {
        case .firstRun:
            section("1. Paste your text", "In Compose, paste the finished text. Choose Clean for no generated mistakes, or Natural for timing and corrections.")
            section("2. Try the preview", "Play preview shows the planned typing inside Typer. It never sends keys to another app.")
            section("3. Allow typing", "In Settings → General, enable Accessibility. Input Monitoring is only for Live capture.")
            section("4. Arm and click your editor", "Click Arm typing. You have five seconds to switch apps and click where the text should begin.")
            section("5. Keep that field focused", "Let Typer finish, then check the text. The red overlay shows pause and stop shortcuts; mouse clicks pass through it.")
            section("Pause or stop", "⌘⌥P pauses and resumes. Return to the same field before resuming. ⌘ Esc or ⌃ Esc stops; text already typed stays in place.")
        case .controls:
            section("Choose a rhythm", "Natural uses the built-in model. Clean skips generated mistakes. My rhythm uses your active profile, with built-in timing where training is limited.")
            section("Adjust the feel", "Speed sets the target WPM. Variation changes timing; Mistake frequency changes errors and repairs. Pauses and repairs make the final average slower.")
            section("Three kinds of pauses", "Thought pauses: occasional 2–5 second waits. Extended thought pauses: rare 2–45 second waits, when Thought pauses is on. Sentence pauses: a wait after each sentence with more text to follow, starting at 2–10 seconds.")
            section("Learn your pause habits", "In My rhythm, Learned pause habits uses your recorded pause frequency and length when enough evidence is available. Check Profiles → Training coverage.")
            section("Save a setup", "Use Preset → Save… to keep your settings. Controls are also remembered when you quit. Source text is never saved.")
            details("More controls") {
                section("Sentence pause range", "Set Min and Max from 1–60 seconds; equal values give a fixed wait. These pauses work in Clean too. At the same point, the longer pause wins. Unusual abbreviations can confuse sentence detection.")
                section("Repairs, drift, and overlay", "Delayed repairs lets a few characters pass before a correction. Fatigue drift changes the pace over a run. Fullscreen typing overlay toggles the red tint; shortcuts work either way.")
                section("Preview and estimate", "The estimate includes planned waits and repairs. Arm typing uses the previewed plan unless you change the text, settings, or profile. ⌘⌥→ skips the current long wait.")
            }
        case .training:
            section("Pick a mode", "Copy follows a passage and learns exact mistakes. Freewrite learns from new writing. Sprint learns faster typing. Live capture observes typing in another app.")
            section("Type, then save", "Type naturally; don't paste or invent mistakes. Save to My rhythm when ready. Save before leaving Train or changing modes; an unfinished exercise resets.")
            section("Samples and profiles", "One sample is one session. My rhythm uses up to five recent samples from the same mode. Saved samples total includes older and Legacy samples too.")
            section("Legacy profiles", QuickHelp.legacyProfile)
            section("Can Live capture run in the background?", "For active writing sessions, up to 15 minutes. Start it, switch to your editor, then return to stop and save. It ignores Typer and pauses for macOS Secure Input.")
            section("What about long idle gaps?", QuickHelp.liveCaptureGaps)
            details("Saving and learning details") {
                section("When Save becomes available", "Copy and Sprint need 60% of the passage and 35 key events; Freewrite needs 117 characters and 35 events. Live capture needs 35 typed characters and must be stopped first.")
                section("What is kept", "Typer keeps 12 current samples, plus Legacy samples separately. Saving rebuilds and activates My rhythm. Copy, Freewrite, Sprint, and Live evidence stay separate.")
                section("Learned pauses", "Each pause category needs 20 opportunities, three observed pauses, and two sessions before it affects playback. Until then, Typer uses its usual timing.")
            }
        case .measurements:
            section("Speed and key dwell", "Speed is words per minute, using five characters per word. Dwell is how long you hold a key down.")
            section("Signed flight and rollover", "Flight is the gap from releasing one key to pressing the next. Negative means overlap. Rollover is the share of key pairs that overlap.")
            section("Interval MAD and bursts", "MAD describes the typical spread in time between presses. Burst length counts keys typed in quick succession.")
            section("Corrections and detection distance", "Deletes per character includes both mistakes and revisions. Detection distance estimates how far you typed past an error before correcting it; it needs a reference passage.")
            section("A dash means unavailable", "There isn't enough usable evidence for that measurement. It doesn't mean zero. Hover or click a question mark beside a number for its definition.")
        case .validation:
            section("1. Save four comparable sessions", "Use the same training mode. Finish Copy or Sprint passages exactly for a matched-text comparison. Legacy samples cannot be validated.")
            section("2. Open Profiles → Validate rhythm", "Choose the training mode. Typer compares Natural and My rhythm against two sessions kept out of training. Your active profile is unchanged.")
            section("3. Look for smaller distances", "Lower W1 and KS mean a closer match for that measurement. Check several measurements and the Human vs human comparison, not just one number.")
            section("Check real playback too", "Profiles → Check playback on this Mac tests a built-in passage in a dedicated editor. Keep it focused and don't type. Escape stops the check.")
            section("What the results mean", "Rhythm validation compares planned timing. Playback checks measure actual delivery in Typer's test editor. Neither proves overall realism or guarantees another app behaves the same.")
            details("Report details") {
                section("Eligible sessions", "Each session needs at least 20 usable paired timings. Two latest eligible sessions are held out; up to five earlier sessions train the comparison profile. Modes are never mixed.")
                section("Distances and counts", "W1 uses the measurement's units, such as milliseconds. KS runs from 0–1. Compare retained counts, pause frequency, rollover, and timing spread. Neither distance is a probability.")
                section("Repeated trials", "Three seeds reuse the same two held-out human sessions. These are repeated simulations, not six independent human tests. The human comparison is context, not a pass threshold.")
                section("Playback results", "Text and event checks are separate from timing errors. Median and p95 errors show timing accuracy; arrival vs event timestamp shows queue delay. Other editors can handle keys differently.")
                section("Export and repeat", "Export report saves measurements and limitations as JSON. After tuning against a report, collect fresh sessions for the next comparison.")
            }
        case .privacy:
            section("Two separate permissions", "Accessibility lets Typer send keys. Input Monitoring is only for opt-in Live capture. Manage both in Settings → General.")
            section("Recording is explicit", "Live capture starts only when you click Start live capture. Stop capture stays visible in the header. It ignores Typer and pauses for macOS Secure Input, which depends on the other app.")
            section("Your data stays here", "Profiles, statistics, settings, and presets stay on this Mac. Live capture drops raw keystrokes when stopped. Freewrite and Live samples don't save the original text.")
            section("What statistics can contain", "Statistics can include character pairs and error patterns, so they aren't necessarily anonymous. Copy and Sprint samples can retain the built-in passage.")
            section("Remove learned data", "Profiles → Delete all learned data removes saved samples and learned profiles. Settings, presets, exported reports, and text in other apps are kept.")
            section("Before quitting", "Save unfinished training and copy any Compose text you want to keep. Compose and preview text exist only in memory.")
        case .updates:
            section("Check while the app is open", "Use Settings → General → Check now. No restart is needed to find an update. Automatic checks run at launch and every six hours.")
            section("Install when you're ready", "New app code requires a relaunch. The update prompt handles it. Save unfinished training and copy your source text first.")
            section("Release or Edge?", "Release gets versioned releases. Edge gets the latest successful build published from main. Choose the channel in General.")
            section("Nothing new available?", "Check the version and build date in General. A commit needs a successful published build before it can appear as an update. An older published build won't replace a newer local build.")
            section("Built the app yourself?", "Local changes need a rebuild and a relaunch. Check now only finds published updates; it can't load local edits.")
        case .troubleshooting:
            section("Nothing gets typed", "Check Accessibility in General. During the countdown, switch to another app and click an editable field. Try a short Clean-mode run in a plain-text document.")
            section("Typing goes to the wrong place", "Stop with ⌘ Esc or ⌃ Esc. Typer pauses when you switch apps, but can't detect every cursor or field change inside one app.")
            section("Pause won't resume", "Return to the original app and the same field, then press ⌘⌥P. If the document changed, stop and check the partial text before starting again.")
            section("Corrections look wrong", "Try Clean first. Autocorrect, keyboard layouts, formatting, and editor shortcuts can change how keys are handled.")
            section("Save or validation is unavailable", "Keep typing until Save is enabled. Validation needs four eligible sessions in one mode. Mixed modes and Legacy samples don't qualify together.")
            section("Live capture shows no typing", "Check Input Monitoring and click Start live capture. Type outside Typer. Secure Input pauses recording; the session ends after 15 minutes.")
        }
    }

    private func section(_ title: String, _ body: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.system(size: 13, weight: .semibold)).accessibilityAddTraits(.isHeader)
            Text(body).font(.system(size: 12)).foregroundStyle(TyperTheme.mutedStrong)
                .lineSpacing(3).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func details<Content: View>(_ title: String, @ViewBuilder content: @escaping () -> Content) -> some View {
        DisclosureGroup(title) {
            VStack(alignment: .leading, spacing: 18, content: content).padding(.top, 14)
        }
        .font(.system(size: 12, weight: .medium)).tint(TyperTheme.mutedStrong)
    }

    private func shortcut(_ keys: String, _ action: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(keys).font(.system(size: 11, weight: .medium, design: .monospaced))
            Text(action).font(.system(size: 10)).foregroundStyle(TyperTheme.mutedStrong)
        }
    }
}
