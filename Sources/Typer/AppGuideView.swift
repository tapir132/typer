import SwiftUI

enum GuideTopic: String, CaseIterable, Identifiable {
    case firstRun = "Your first run"
    case controls = "Modes & controls"
    case training = "Train your rhythm"
    case measurements = "Read the measurements"
    case validation = "Validate a profile"
    case privacy = "Permissions & data"
    case updates = "Builds & updates"
    case troubleshooting = "Troubleshooting"

    var id: String { rawValue }
    var symbol: String {
        switch self {
        case .firstRun: return "play.rectangle"
        case .controls: return "slider.horizontal.3"
        case .training: return "keyboard"
        case .measurements: return "waveform.path"
        case .validation: return "chart.xyaxis.line"
        case .privacy: return "lock.shield"
        case .updates: return "arrow.down.circle"
        case .troubleshooting: return "questionmark.circle"
        }
    }
    var introduction: String {
        switch self {
        case .firstRun: return "Give Typer the finished text, then let it type into an editor you choose."
        case .controls: return "Choose a timing source, then adjust the pace, pauses, and corrections independently."
        case .training: return "Capture how you actually type. Genuine pauses and corrections are useful observations."
        case .measurements: return "A typing fingerprint describes a pattern across many keystrokes. Each number tells a different part of that story."
        case .validation: return "Compare generated timing with sessions kept out of training. Look for evidence of a closer match across several measurements."
        case .privacy: return "Playback and Live capture use separate macOS permissions. Learned data is stored locally."
        case .updates: return "The updater checks for published builds. A local development build has its own build date and may already be newer."
        case .troubleshooting: return "Start with the symptom, then check the setting or step that controls it."
        }
    }
}

struct AppGuideView: View {
    @ObservedObject var model: AppModel
    var onClose: (() -> Void)? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 26) {
            VStack(alignment: .leading, spacing: 7) {
                Text("Get to know Typer.").font(.system(size: 27, weight: .semibold)).tracking(-0.5)
                Text("Start with a short practice run. Come back here whenever you need a hand.")
                    .font(.system(size: 13)).foregroundStyle(TyperTheme.mutedStrong)
            }
            HStack(alignment: .top, spacing: 32) {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(GuideTopic.allCases) { topic in
                        Button { model.guideTopic = topic } label: {
                            HStack(spacing: 9) {
                                Image(systemName: topic.symbol).frame(width: 18)
                                Text(topic.rawValue)
                                Spacer(minLength: 0)
                            }
                            .font(.system(size: 12, weight: model.guideTopic == topic ? .semibold : .regular))
                            .foregroundStyle(model.guideTopic == topic ? TyperTheme.signal : TyperTheme.mutedStrong)
                            .padding(.horizontal, 10).frame(minHeight: 40)
                            .background(model.guideTopic == topic ? TyperTheme.surface : .clear)
                            .clipShape(RoundedRectangle(cornerRadius: 7))
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityAddTraits(model.guideTopic == topic ? .isSelected : [])
                    }
                    Rectangle().fill(TyperTheme.line).frame(height: 1).padding(.vertical, 12)
                    Text("STOP PLAYBACK")
                        .font(.system(size: 9, weight: .semibold, design: .monospaced)).foregroundStyle(TyperTheme.muted)
                    Text("⌘ Esc  or  ⌃ Esc")
                        .font(.system(size: 12, weight: .medium, design: .monospaced)).padding(.top, 3)
                    Text("Available while another app is active.")
                        .font(.system(size: 11)).foregroundStyle(TyperTheme.mutedStrong).lineSpacing(3).padding(.top, 4)
                }
                .frame(width: 188)

                VStack(alignment: .leading, spacing: 22) {
                    VStack(alignment: .leading, spacing: 9) {
                        Text(model.guideTopic.rawValue).font(.system(size: 21, weight: .semibold))
                            .accessibilityAddTraits(.isHeader)
                        Text(model.guideTopic.introduction).guideBody()
                    }
                    Rectangle().fill(TyperTheme.line).frame(height: 1)
                    topicContent
                }
                .frame(maxWidth: 660, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
            }
        }
        .padding(.horizontal, TyperLayout.workspaceHorizontalPadding)
        .padding(.top, TyperLayout.workspaceTopPadding)
        .padding(.bottom, 36)
        .foregroundStyle(TyperTheme.ink)
    }

    @ViewBuilder private var topicContent: some View {
        switch model.guideTopic {
        case .firstRun:
            section("1. Prepare a short message", "Open Compose and paste the complete text into Source text. Paste replaces the text currently in that box. For a first run, use a short paragraph in an empty document so you can watch what happens.")
            section("2. Pick a starting mode", "Choose Clean for timing and pauses without generated mistakes, or Natural for the built-in timing and correction model. My rhythm becomes useful after you save training samples. Start at a comfortable typing speed; the estimate includes the planned pauses and repairs.")
            section("3. Enable Accessibility", "Open the gear in the top-right corner. Request Accessibility permission, then enable Typer in System Settings → Privacy & Security → Accessibility. Return to Typer; the permission status refreshes automatically. Input Monitoring is only needed for optional Live capture.")
            section("4. Arm, then focus your editor", "Click Arm typing or press ⌘ Return in Typer. During the five-second countdown, switch to your destination app and click inside an editable text field. The cursor should be exactly where you want the text to begin. Playback cancels if Typer is still the active app when the countdown ends.")
            section("5. Let the run finish", "Keys go to the active app. Keep that app and text field focused until Typer finishes. Generated mistakes are followed by planned corrections intended to restore your source text. An editor's autocorrect, shortcuts, or formatting can affect the result, so check the finished text.")
            note("Need to stop?", "Press ⌘ Esc or ⌃ Esc, or return to Typer and click Stop typing. Stopping leaves the text already entered in the destination; it does not undo the run.")
            actions { open("Open Compose", section: .compose); setupButton }
        case .controls:
            section("Natural, Clean, and My rhythm", "Natural uses the built-in model. Clean uses human-style timing and pauses with generated mistakes disabled. My rhythm uses the active learned profile and blends limited observations with the baseline. If there is no learned profile, it falls back to generic timing; Compose tells you which source is in use.")
            section("Typing speed and the estimate", "Typing speed is a target in words per minute, using five characters per word. Pauses, deletions, and retyping add time, so the final average can be slower than the slider value. The duration below Source text is the estimate for the current plan.")
            section("Human variation", "This changes the amount of variation in key holds, gaps, bursts, and hesitation. The percentage is a control setting. It is not a realism score or a probability that the output is human. To adjust how many mistakes appear, use Mistake frequency separately.")
            section("Mistakes and delayed repairs", "Mistake frequency controls generated errors and their repairs. Clean disables them. Delayed repairs lets some errors remain for a few characters before Typer returns to correct them. The repair count beside Rhythm preview describes the current plan; shorter text may have no generated repairs.")
            section("Thought pauses and fatigue", "Thought pauses adds occasional stalls of about 2–5 seconds. Extended thought pauses also allows a 2–45 second pause at a sentence ending, with a 2.5% chance at each eligible ending. It requires Thought pauses. Fatigue drift gradually changes the cadence over a run.")
            section("Reading the preview", "The waveform is a compact illustration of timing, with highlighted backspaces. It is not a playback recording. Once refreshed, the preview plan is also the plan used by Arm typing; changing text, settings, or the active profile refreshes it.")
            actions { open("Adjust in Compose", section: .compose); topicButton("Learn about training", .training) }
        case .training:
            section("Choose the task you want to learn", "Copy: type the displayed passage and correct real errors normally. Freewrite: compose a few new sentences directly in the box, including your usual thinking pauses and revisions. Sprint: copy the prompt at a brisk, natural pace. Avoid pasting text or deliberately inventing errors; those actions do not represent normal typing.")
            section("When to save", "In Copy and Sprint, Save to My rhythm becomes available after you type at least 60% of the passage and record at least 35 key events. Freewrite needs at least 117 characters and 35 key events. Aim to finish the passage or write several sentences for a more useful sample. Save before changing mode, choosing another passage, or leaving Train: the in-app exercise resets when you leave.")
            section("How samples become My rhythm", "Saving activates My rhythm in Compose. Typer retains the 12 most recent current samples, keeps Legacy samples separately, and builds My rhythm from up to five recent current samples in the same mode as the one you just saved. Copy, Freewrite, Sprint, and Live capture are kept as different task contexts. Trying a different mode changes which context supplies the profile; it does not blend every task together.")
            section("Saved samples versus a trained profile", "A sample is one recorded typing session. The saved total counts every retained session, including older recordings and other modes. The count under a profile tells you how many samples were used to build it. For example, four older samples plus one new Copy sample means five saved in total, while My rhythm is trained on one Copy sample. The four older samples belong to a separate Legacy profile. They cannot be added to the current profile because they lack the required recording details.")
            section("Legacy profiles are locked for training", "Older profiles are labeled Legacy and remain available for playback. You cannot add recordings to them or validate them with the new system. New recordings train a separate My rhythm profile, even when a Legacy profile is selected for playback. Your Legacy profile stays unchanged. If an earlier app build already replaced it, Typer restores a separate Legacy rhythm from the older samples still saved on this Mac. Collect four usable new sessions in one mode to validate the current model.")
            section("Record in another app with Live capture", "Choose Live capture and enable Input Monitoring if requested. Click Start live capture, switch to your editor, and type normally. Return to Typer and click Stop capture, then review the measurements and choose Save to My rhythm or Discard. A stopped session needs at least 35 typed characters to save; sessions stop automatically after 15 minutes.")
            note("Live capture is opt-in", "It records outside Typer only during the session and pauses while macOS Secure Input is active. Secure Input depends on the destination app; it is not a detector for every sensitive field. Stop the session before entering private information. Raw keystrokes are discarded when recording stops; saved statistics can still contain character pairs.")
            section("Build evidence over multiple sessions", "A single sample is a starting point. Collect several sessions in the same mode, ideally at different times. Four new sessions with enough paired timings enable validation. More samples do not guarantee a closer match; use the held-out comparisons to check.")
            actions { open("Open Train", section: .train); topicButton("Understand the measurements", .measurements) }
        case .measurements:
            section("Speed and key dwell", "Speed expresses typing pace as words per minute. Key dwell, also called key hold, is the time from pressing a key to releasing it, measured in milliseconds. The fingerprint summarizes observed holds; missing releases are kept as missing data.")
            section("Press interval and signed flight", "Press interval is the time from one key press to the next. Signed flight measures the time from releasing the first key to pressing the next. Positive flight means a gap. Negative flight means the next key was pressed while the previous key was still down.")
            section("Rollover", "Rollover is the share of eligible neighboring character pairs with negative flight. For example, pressing B 20 ms before releasing A gives a flight of −20 ms. This is normal key overlap. Pairs with missing holds or a break in the sequence are excluded.")
            section("Interval MAD and bursts", "Interval MAD is the median absolute deviation of press intervals: a typical amount of variation around the median interval. A larger value means a wider spread. Burst length counts consecutive keys separated by intervals below 310 ms; this cutoff is a modeling choice, not a universal boundary for human thought.")
            section("Corrections and detection distance", "Deletes per character describes deletion actions relative to typed characters. A deletion can be a typo correction or a change of mind. Detection distance is only estimated where the known prompt supports identifying an error; Freewrite and Live capture cannot establish exactly what you intended to type.")
            section("A dash means unavailable", "Some measurements need completed key releases, repeated character pairs, or a known reference passage. A dash means the required evidence is absent. It does not mean zero, and filling it with a guessed number would make the comparison misleading.")
            actions { open("Open Profiles", section: .profiles); topicButton("Read validation results", .validation) }
        case .validation:
            section("1. Collect comparable sessions", "Save at least four new sessions in the same training mode, each with at least 20 usable paired timings. Copy is a useful starting point because Typer knows the reference passage. Older samples without paired timing evidence do not count toward this requirement. The report uses the mode of your latest saved sample.")
            section("2. Open the report", "Go to Profiles → Validate rhythm. Typer keeps the two latest eligible sessions out of training and fits a temporary comparison profile using up to five earlier sessions in that mode. This does not replace your active profile. The comparisons run locally.")
            section("3. Compare Natural and My rhythm", "The comparison menu offers both modes against each held-out human session. Each uses the same target WPM and three fixed random seeds (17, 41, and 89). Copy and Sprint use their reference prompts; Freewrite and Live capture use a standard passage because their original text is not stored. Those unmatched-text results also reflect differences between passages.")
            section("4. Read distances in context", "W1 distance measures the separation between distributions in the feature's units, such as milliseconds for key hold. KS distance measures their largest cumulative difference on a 0–1 scale. Lower means closer for that feature. Check the retained counts, missing holds, rollover, and the human-session-versus-human-session comparison before drawing conclusions.")
            note("What this can establish", "The report compares planned timelines with stored observations. It does not measure how another app actually receives keys, prove that a profile is human, or certify overall realism. Similar medians can hide different distributions. A small distance on one feature can coexist with a poor match on another.")
            section("5. Export and repeat", "Export report saves a JSON file with the comparison data, seeds, counts, and limitations. After changing the model based on a report, collect fresh sessions for a new evaluation; repeatedly tuning against the same held-out sessions weakens their value as an independent check.")
            actions { open("Open Profiles", section: .profiles); open("Collect samples", section: .train) }
        case .privacy:
            section("Accessibility: typing into another app", "Accessibility allows Typer to send the planned key events. Open System setup using the gear, request the permission, and enable Typer in macOS settings. It is required for playback, including Clean mode. The permission status refreshes while System setup is open.")
            section("Input Monitoring: optional Live capture", "Input Monitoring allows the opt-in session to observe key events in other apps. Copy, Freewrite, and Sprint in Typer do not require it. Granting the permission does not start a recording; Start live capture does. The red Stop capture control in the header shows when a session is active.")
            section("What is saved", "Profiles and training statistics stay in this Mac's local preferences. Live capture keeps raw keystrokes in memory only until the session stops, then retains derived statistics for review. Saved data can include character pairs and confusion patterns; derived data is not necessarily anonymous. Copy and Sprint samples can include the built-in reference passage, but Freewrite and Live capture do not save the original text.")
            section("Delete learned data", "Open Profiles and choose Delete all learned data to remove saved samples and learned profiles. Typer returns to the built-in baseline. Exported validation files are separate files you manage yourself, and deleting learned data does not remove text previously typed into another app.")
            section("Revoking a permission", "You can turn off Typer's permissions in System Settings → Privacy & Security. Playback and Live capture check their respective permissions when starting. If macOS asks you to quit and reopen Typer after a change, save your work first and follow that instruction.")
            actions { setupButton; open("Manage profiles", section: .profiles) }
        case .updates:
            section("Identify the app that is running", "Open System setup and look under Updates for the version, build origin, and local build date. A version containing “local” was built on this Mac. Rebuilding can keep the same commit suffix while changing the app's contents and build date. An already-running process continues using the code it launched with until you quit and reopen it.")
            section("Release and Edge", "Release checks versioned releases. Edge checks the rolling build published after a successful push to main. Editing files locally does not publish an update to either channel. Both depend on a successful build and release publication, so a new commit alone does not guarantee that a downloadable build exists.")
            section("Use Check now", "Check now asks for a published update and displays the result, latest published version when available, and check time. If the feed cannot be reached or verified, an error appears. A completed check with no newer compatible build is a normal result.")
            section("Checking does not require a restart", "Typer can discover and download updates while it stays open. Check now checks immediately; automatic checking checks at launch and every six hours. To start using new app code, the app must relaunch. Accept the update's installation and relaunch prompt to let Sparkle handle that, or defer it until you are ready. Save unfinished training and copy any source text you want to keep before installing.")
            section("Why a local build can be newer", "Updates are ordered by the internal build number. Local builds use their build time, so a fresh local build can be newer than the published Release or Edge build even when the visible version labels look different. The updater then has no newer build to offer.")
            section("Automatic checking and installation", "Check automatically enables checks at launch and every six hours. Install automatically allows Sparkle to download and install verified updates when available. Turn it off to review offered updates yourself. Sparkle verifies the release signature before replacing the app.")
            note("Local changes need a relaunch", "If you built Typer yourself, save any unfinished training sample and copy source text you want to keep, then quit and reopen the rebuilt app. Check its build date afterward. Check now cannot load unpublished local edits into an older running process.")
            actions { setupButton }
        case .troubleshooting:
            section("The countdown ends but nothing appears", "Typer must have Accessibility permission and a different app must be active. During the countdown, click inside an editable field in the destination. Try a short Clean-mode run in a plain-text document to check the basic path, then try your intended editor.")
            section("The text lands in the wrong place", "Playback follows the active app and insertion point. Stop with ⌘ Esc or ⌃ Esc, correct the destination, and decide whether to remove the partial output before trying again. Typer does not remember or lock the original destination field.")
            section("Corrections produce unexpected text", "Editors interpret deletion, selection, autocorrect, and shortcuts differently. Start with Clean to check text entry, then enable mistakes. Keyboard layout and app behavior can affect the result. Inspect the destination text after each trial; the plan alone cannot validate the editor's response.")
            section("Save to My rhythm is disabled", "Continue typing directly in the training field until the sample threshold is met. Copy and Sprint need at least 60% of the passage; Freewrite needs at least 117 characters. Both also require 35 recorded key events. For Live capture, stop recording first and check that at least 35 characters were captured outside Typer.")
            section("Validation still asks for four sessions", "The sessions must be new enough to contain paired timing evidence, have at least 20 usable pairs each, and share the latest sample's training mode. Four saved samples across different modes may not qualify. Missing key releases can also reduce the usable pair count.")
            section("Live capture shows no new characters", "Check Input Monitoring in System setup and confirm you clicked Start live capture. Type in a different app; Typer's own events are excluded. Capture pauses for macOS Secure Input and ends after 15 minutes. Stop and review the session before saving it.")
            section("A change is missing, but there are no updates", "Check the version and build date in System setup. Local changes need a rebuild and a relaunch. Published updates need a successful release on the chosen channel. A newer local build will not be replaced by an older published build.")
            actions { setupButton; topicButton("Review the first-run steps", .firstRun) }
        }
    }

    private func section(_ title: String, _ body: String) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title).font(.system(size: 14, weight: .semibold)).accessibilityAddTraits(.isHeader)
            Text(body).guideBody()
        }
    }

    private func note(_ title: String, _ body: String) -> some View {
        section(title, body).padding(16).frame(maxWidth: .infinity, alignment: .leading)
            .background(TyperTheme.surface)
            .overlay(alignment: .leading) { Rectangle().fill(TyperTheme.signal).frame(width: 2) }
    }

    private func actions<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        HStack(spacing: 10, content: content).padding(.top, 4)
    }

    private func open(_ title: String, section: AppSection) -> some View {
        Button(title) { model.section = section; onClose?() }.buttonStyle(SecondaryButtonStyle())
    }

    private func topicButton(_ title: String, _ topic: GuideTopic) -> some View {
        Button(title) { model.guideTopic = topic }.buttonStyle(QuietButtonStyle())
    }

    private var setupButton: some View {
        Button("Open System setup") {
            onClose?()
            // A contextual guide may be presented as a sheet. Let it dismiss
            // before requesting the setup sheet from the root workspace.
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(200))
                model.showsSystemSetup = true
            }
        }.buttonStyle(SecondaryButtonStyle())
    }
}

struct AppGuideSheet: View {
    @ObservedObject var model: AppModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            HStack { Spacer(); Button("Done") { dismiss() }.buttonStyle(QuietButtonStyle()).keyboardShortcut(.cancelAction) }
                .padding(.horizontal, 20).padding(.top, 10)
            ScrollView { AppGuideView(model: model, onClose: { dismiss() }) }
        }
        .frame(width: 850, height: min(740, (NSScreen.main?.visibleFrame.height ?? 820) - 80))
        .background(TyperTheme.background)
    }
}

private extension Text {
    func guideBody() -> some View {
        font(.system(size: 12)).foregroundStyle(TyperTheme.mutedStrong)
            .lineSpacing(5).fixedSize(horizontal: false, vertical: true)
    }
}
