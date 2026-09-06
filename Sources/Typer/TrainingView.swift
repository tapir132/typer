import SwiftUI

struct TrainingView: View {
    @ObservedObject var model: AppModel
    @ObservedObject private var profiles: ProfileStore
    @ObservedObject private var liveCapture: GlobalTrainingCapture
    @State private var passageIndex = 0
    @State private var input = ""
    @State private var records: [TrainingKeyRecord] = []
    @State private var startedAt: Double?
    @State private var lastMistakeAt: Double?
    @State private var activePresses: [UInt16: UUID] = [:]
    @State private var showsTrainingGuide = false

    private let passages = [
        "The tiny bookstore stayed open after midnight, its windows glowing against the rain. I stepped inside for five minutes and left an hour later with three novels and a new favorite place.",
        "We shipped the rough version on Friday afternoon. By Monday, people were using it in ways we had never considered, which was both terrifying and exactly what we hoped would happen.",
        "A good tool disappears while you use it. The controls feel obvious, the feedback arrives at the right moment, and the difficult work starts to feel strangely effortless.",
        "When the train crossed the bridge, every window caught the last orange light. For a few seconds, the whole carriage went quiet and watched the city appear below."
    ]

    init(model: AppModel) {
        self.model = model
        profiles = model.profiles
        liveCapture = model.liveCapture
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 7) {
                    Text("Teach it your rhythm.").font(.system(size: 27, weight: .semibold)).tracking(-0.5)
                    Text("Type naturally—correct mistakes, pause, and change your mind like you normally would.").font(.system(size: 13)).foregroundStyle(TyperTheme.mutedStrong)
                }
                Spacer()
                Button { model.guideTopic = .training; showsTrainingGuide = true } label: {
                    Label("How training works", systemImage: "questionmark.circle")
                }
                .buttonStyle(QuietButtonStyle())
                HStack(alignment: .top, spacing: 5) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("\(profiles.samples.count) saved samples total")
                            .font(.system(size: 11, weight: .semibold)).foregroundStyle(TyperTheme.signal)
                        Text("\(profiles.activeProfile.sampleCount) used by active profile")
                            .font(.system(size: 10)).foregroundStyle(TyperTheme.mutedStrong)
                    }
                    HelpTip(title: "Saved samples and profile training", text: profiles.sampleUsageExplanation)
                }
            }
            .padding(.bottom, 24)

            if let note = profiles.unusedOlderSamplesNote {
                Text(note).font(.system(size: 11)).foregroundStyle(TyperTheme.mutedStrong)
                    .fixedSize(horizontal: false, vertical: true).padding(.bottom, 16)
            }

            HStack(alignment: .top, spacing: 0) {
                trainingStage
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(.trailing, 30)
                fingerprint
                    .frame(width: 286)
                    .padding(.leading, 28)
                    .overlay(alignment: .leading) { Rectangle().fill(TyperTheme.line).frame(width: 1) }
            }
            .overlay(alignment: .top) { Rectangle().fill(TyperTheme.line).frame(height: 1) }
            .overlay(alignment: .bottom) { Rectangle().fill(TyperTheme.line).frame(height: 1) }
        }
        .padding(.horizontal, TyperLayout.workspaceHorizontalPadding)
        .padding(.top, TyperLayout.workspaceTopPadding)
        .padding(.bottom, TyperLayout.workspaceBottomPadding)
        .onChange(of: model.trainingMode) { _, newMode in
            if newMode != .liveCapture { reset(changePassage: false) }
        }
        .sheet(isPresented: $showsTrainingGuide) { AppGuideSheet(model: model) }
    }

    private var mode: TrainingMode { model.trainingMode }

    private var trainingStage: some View {
        VStack(alignment: .leading, spacing: 0) {
            ViewThatFits(in: .horizontal) {
                HStack {
                    trainingModePicker
                    Spacer()
                    anotherPassageButton
                }
                VStack(alignment: .leading, spacing: 6) {
                    trainingModePicker
                    anotherPassageButton
                }
            }
            .frame(minHeight: 58)
            .padding(.vertical, 8)

            if mode == .liveCapture {
                liveCaptureStage
            } else {
                standardTrainingStage
            }
        }
    }

    private var trainingModePicker: some View {
        HStack(spacing: 5) {
            Picker("Training mode", selection: $model.trainingMode) {
                ForEach(TrainingMode.allCases) { mode in Text(mode.rawValue).tag(mode) }
            }
            .labelsHidden().pickerStyle(.segmented).frame(width: 410)
            HelpTip(title: "Training mode", text: QuickHelp.trainingMode)
        }
    }

    @ViewBuilder private var anotherPassageButton: some View {
        if mode != .freewrite && mode != .liveCapture {
            Button("Try another passage") { reset(changePassage: true) }
                .buttonStyle(QuietButtonStyle()).fixedSize()
        }
    }

    private var standardTrainingStage: some View {
        VStack(alignment: .leading, spacing: 0) {
            trainingInstructions

            VStack(alignment: .leading, spacing: 8) {
                Text(mode == .freewrite ? "WRITE NATURALLY" : mode == .sprint ? "TYPE FAST—ACCURACY SECOND" : "COPY THIS PASSAGE")
                    .font(.system(size: 9, weight: .semibold, design: .monospaced)).foregroundStyle(TyperTheme.signal)
                Text(prompt)
                    .font(.system(size: mode == .freewrite ? 16 : 17, design: .monospaced))
                    .foregroundStyle(TyperTheme.mutedStrong).lineSpacing(7).textSelection(.enabled)
            }
            .frame(maxWidth: 760, minHeight: 112, alignment: .topLeading)

            TrackingTextView(text: $input, placeholder: "Start typing…", onKeyDown: captureDown, onKeyUp: captureUp)
                .background(TyperTheme.surface)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay { RoundedRectangle(cornerRadius: 12).stroke(TyperTheme.line, lineWidth: 1) }
                .frame(minHeight: 175)
                .padding(.top, 22)

            HStack {
                Text(feedback).font(.system(size: 10)).foregroundStyle(TyperTheme.muted)
                Spacer()
                Button("Save to My rhythm") { saveSample() }.buttonStyle(SecondaryButtonStyle()).disabled(!canSave)
            }
            .padding(.top, 11)
        }
    }

    private var trainingInstructions: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(mode.description).font(.system(size: 10, weight: .medium)).foregroundStyle(TyperTheme.mutedStrong)
            Text(mode.instruction).font(.system(size: 10)).foregroundStyle(TyperTheme.muted).lineSpacing(3)
        }
        .padding(.bottom, 18)
    }

    private var liveCaptureStage: some View {
        VStack(alignment: .leading, spacing: 18) {
            trainingInstructions

            HStack(spacing: 16) {
                Image(systemName: liveCapture.isCapturing ? "record.circle.fill" : "keyboard.badge.ellipsis")
                    .font(.system(size: 24, weight: .medium))
                    .foregroundStyle(liveCapture.isCapturing ? TyperTheme.danger : TyperTheme.signal)
                    .frame(width: 42, height: 42)
                    .background(TyperTheme.raised)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))

                VStack(alignment: .leading, spacing: 4) {
                    Text(liveCaptureTitle).font(.system(size: 13, weight: .semibold))
                    Text(liveCaptureDetail).font(.system(size: 10)).foregroundStyle(TyperTheme.mutedStrong)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 3) {
                    Text("\(liveCapture.characterCount) typed").font(.system(size: 13, weight: .semibold, design: .monospaced))
                    Text("\(liveCapture.backspaceCount) repairs · \(formatCaptureDuration(liveCapture.elapsedMilliseconds))")
                        .font(.system(size: 9, design: .monospaced)).foregroundStyle(TyperTheme.muted)
                }
            }
            .padding(18)
            .background(TyperTheme.surface)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "lock.shield.fill").foregroundStyle(TyperTheme.signal)
                Text("Opt-in session only. Typer never blocks or rewrites the target app's events. Raw keystrokes exist only in memory while recording and are discarded when you stop; only timing statistics are saved.")
                    .font(.system(size: 10)).foregroundStyle(TyperTheme.mutedStrong).lineSpacing(3)
            }

            if let notice = liveCapture.notice {
                Text(notice).font(.system(size: 10, weight: .medium)).foregroundStyle(TyperTheme.danger)
            }

            HStack(spacing: 10) {
                if liveCapture.isCapturing {
                    Button("Stop capture") { stopLiveCapture() }.buttonStyle(SecondaryButtonStyle())
                    Button("Discard session") { liveCapture.discard() }.buttonStyle(QuietButtonStyle())
                } else {
                    Button(liveCapture.characterCount > 0 ? "Start over" : "Start live capture") { startLiveCapture() }
                        .buttonStyle(SecondaryButtonStyle())
                    if liveCapture.characterCount > 0 {
                        Button("Save to My rhythm") { saveLiveSample() }
                            .buttonStyle(SecondaryButtonStyle())
                            .disabled(!liveCapture.canSave)
                        Button("Discard") { liveCapture.discard() }.buttonStyle(QuietButtonStyle())
                    }
                }
            }

            Text("A useful session needs at least \(GlobalTrainingCapture.minimumCharacters) typed characters. Recording stops automatically after 15 minutes and pauses whenever macOS Secure Input is active.")
                .font(.system(size: 9)).foregroundStyle(TyperTheme.muted).lineSpacing(2)
            Spacer()
        }
    }

    private var fingerprint: some View {
        let snapshot = sample
        let evidence = snapshot?.evidence
        return VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Live fingerprint").font(.system(size: 12, weight: .semibold))
                Spacer()
                HStack(spacing: 5) {
                    Circle().fill(fingerprintStatusColor).frame(width: 5, height: 5)
                    Text(fingerprintStatus)
                }
                .font(.system(size: 8, weight: .medium, design: .monospaced)).foregroundStyle(fingerprintStatusColor)
                .padding(.horizontal, 7).padding(.vertical, 5).background(fingerprintStatusColor.opacity(0.09)).clipShape(Capsule())
            }
            .frame(height: 58)

            MetricRow(label: "Speed", help: QuickHelp.measuredSpeed, value: snapshot.map { "\(Int($0.wpm.rounded())) WPM" } ?? "—")
            MetricRow(label: "Dwell time", help: QuickHelp.dwell, value: evidence.flatMap { $0.dwells.isEmpty ? nil : "\(Int(TypingEngine.median($0.dwells).rounded())) ms" } ?? "—")
            MetricRow(label: "Signed flight", help: QuickHelp.flight, value: evidence.flatMap { $0.pairs.values.isEmpty ? nil : "\(Int(TypingEngine.median($0.pairs.values.map(\.flight)).rounded())) ms" } ?? "—")
            MetricRow(label: "Rollover", help: QuickHelp.rollover, value: evidence?.rolloverRate.map { "\(Int(($0 * 100).rounded()))%" } ?? "—")
            MetricRow(label: "Interval MAD", help: QuickHelp.mad, value: snapshot.map { "\(Int($0.intervalMAD.rounded())) ms" } ?? "—")
            MetricRow(label: "Deletes / char.", help: QuickHelp.corrections, value: snapshot.map { "\(Int(($0.backspaceRate * 100).rounded()))%" } ?? "—")
            MetricRow(label: "Detection distance", help: QuickHelp.detection, value: evidence.flatMap { $0.detectionDistances.isEmpty ? nil : "\(TypingEngine.median($0.detectionDistances).formatted(.number.precision(.fractionLength(1)))) keys" } ?? "—")
            MetricRow(label: "Burst length", help: QuickHelp.bursts, value: evidence.flatMap { $0.burstLengths.isEmpty ? nil : "\(TypingEngine.median($0.burstLengths).formatted(.number.precision(.fractionLength(1)))) keys" } ?? "—")

            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "lock.fill").foregroundStyle(TyperTheme.signal).font(.system(size: 10)).padding(.top, 1)
                Text(mode == .liveCapture ? "Only derived timing statistics are saved. Raw captured text is discarded." : "Stored on this Mac. Raw samples never leave the app.")
                    .font(.system(size: 9)).foregroundStyle(TyperTheme.muted).lineSpacing(2)
            }
            .padding(13).typerSurface(radius: 10).padding(.top, 22)
            Spacer()
        }
    }

    private var prompt: String {
        switch mode {
        case .copy: return passages[passageIndex]
        case .sprint: return "Quick hands make small mistakes; good typists recover without losing the thread. Keep moving and let corrections happen naturally."
        case .freewrite: return "Write 3–5 sentences about what you built today, a problem you solved, or what you want to do next. Don't polish it first."
        case .liveCapture: return ""
        }
    }

    private var target: String { mode == .freewrite ? input : prompt }
    private var elapsed: Double { max(1, (records.last?.pressTime ?? startedAt ?? 0) - (startedAt ?? 0)) }
    private var sample: TrainingSample? {
        if mode == .liveCapture { return liveCapture.previewSample }
        guard records.filter({ $0.kind == .character }).count >= 2 else { return nil }
        return TypingEngine.summarize(records: records, target: target, duration: elapsed, mode: mode)
    }

    private var fingerprintStatus: String {
        if mode != .liveCapture { return "listening" }
        if liveCapture.secureInputActive { return "secure input · paused" }
        if liveCapture.isCapturing { return "recording" }
        if liveCapture.capturedSample != nil { return "ready to save" }
        return "idle"
    }

    private var fingerprintStatusColor: Color {
        mode == .liveCapture && liveCapture.isCapturing ? TyperTheme.danger : TyperTheme.signal
    }

    private var liveCaptureTitle: String {
        if liveCapture.secureInputActive { return "Paused for Secure Input" }
        if liveCapture.isCapturing { return "Recording outside Typer" }
        if liveCapture.capturedSample != nil { return "Session ready to save" }
        return "Ready for an opt-in session"
    }

    private var liveCaptureDetail: String {
        if liveCapture.secureInputActive { return "Capture pauses while macOS Secure Input is enabled." }
        if liveCapture.isCapturing { return "Switch to your editor and type normally. Return here when finished." }
        if liveCapture.characterCount > 0 { return liveCapture.canSave ? "The raw keystrokes have been discarded." : "This session is too short to save; start over or discard it." }
        return "Input Monitoring is used only after you press Start live capture."
    }
    private var progress: Double {
        if mode == .freewrite { return min(1, Double(input.count) / 180) }
        return min(1, Double(input.count) / Double(max(1, prompt.count)))
    }
    private var canSave: Bool { records.count >= 35 && progress >= (mode == .freewrite ? 0.65 : 0.6) }
    private var feedback: String {
        if records.isEmpty { return "Waiting for your first keystroke" }
        if canSave { return "Good sample—save this fingerprint." }
        return "\(Int((progress * 100).rounded()))% captured"
    }

    private func captureDown(_ event: CapturedKey) {
        guard !event.isRepeat else {
            records.append(TrainingKeyRecord(id: UUID(), kind: .boundary, key: "", expected: "", pressTime: event.timestamp, cursor: 0))
            return
        }
        if startedAt == nil { startedAt = event.timestamp }
        if let action = CaptureAction.classify(keyCode: event.keyCode, command: event.modifiers.contains(.command), control: event.modifiers.contains(.control),
                                               option: event.modifiers.contains(.option), shift: event.modifiers.contains(.shift), function: event.modifiers.contains(.function)) {
            records.append(TrainingKeyRecord(id: UUID(), kind: action, key: "", expected: "", pressTime: event.timestamp, cursor: 0))
            lastMistakeAt = nil
            return
        }
        // After a mismatch, offsets no longer establish intended characters.
        let characters = event.keyCode == 36 ? "\n" : event.keyCode == 48 ? "\t" : event.characters
        let aligned = Array(input.utf16.prefix(event.cursor)) == Array(prompt.utf16.prefix(event.cursor))
        let expected = mode == .freewrite || !aligned ? "" : character(atUTF16Offset: event.cursor, in: prompt)
        let record: TrainingKeyRecord
        if event.keyCode == 51 {
            record = TrainingKeyRecord(id: UUID(), kind: .backspace, key: "Backspace", expected: "", pressTime: event.timestamp, cursor: event.cursor, sinceMistake: lastMistakeAt.map { event.timestamp - $0 })
            lastMistakeAt = nil
        } else if characters.count == 1 && !characters.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) && $0 != "\n" && $0 != "\t" }) {
            let id = UUID()
            record = TrainingKeyRecord(id: id, kind: .character, key: characters, expected: expected, pressTime: event.timestamp, cursor: event.cursor)
            activePresses[event.keyCode] = id
            if !expected.isEmpty && characters != expected { lastMistakeAt = event.timestamp }
        } else { return }
        records.append(record)
    }

    private func captureUp(_ event: CapturedKey) {
        guard let id = activePresses.removeValue(forKey: event.keyCode), let index = records.firstIndex(where: { $0.id == id }) else { return }
        records[index].dwell = max(0, event.timestamp - records[index].pressTime)
    }

    private func character(atUTF16Offset offset: Int, in string: String) -> String {
        let utf16 = Array(string.utf16)
        guard offset >= 0 && offset < utf16.count, let scalar = UnicodeScalar(utf16[offset]) else { return "" }
        return String(Character(scalar))
    }

    private func reset(changePassage: Bool) {
        if changePassage { passageIndex = (passageIndex + 1) % passages.count }
        input = ""; records = []; startedAt = nil; lastMistakeAt = nil; activePresses = [:]
    }

    private func startLiveCapture() {
        model.refreshPermissions()
        guard model.inputMonitoringAuthorized else {
            model.showsSystemSetup = true
            model.requestInputMonitoringPermission()
            model.showToast("Allow Input Monitoring, then start Live capture again.")
            return
        }
        if liveCapture.start() {
            model.showToast("Live capture started. Switch to the app where you want to write.")
        } else if let notice = liveCapture.notice {
            model.showToast(notice)
        }
    }

    private func stopLiveCapture() {
        liveCapture.stop()
        model.showToast(liveCapture.canSave ? "Capture stopped. Review and save the sample." : "Capture stopped. At least 35 typed characters are needed.")
    }

    private func saveLiveSample() {
        guard let sample = liveCapture.capturedSample, liveCapture.canSave else { return }
        guard profiles.add(sample: sample) else {
            model.showToast("This sample uses an older format. Start a new recording to train My rhythm.")
            return
        }
        model.settings.mode = .personal
        liveCapture.discard()
        model.showToast("Live capture added to My rhythm.")
    }

    private func formatCaptureDuration(_ milliseconds: Double) -> String {
        let seconds = max(0, Int(milliseconds / 1_000))
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }

    private func saveSample() {
        guard let sample else { return }
        guard profiles.add(sample: sample) else {
            model.showToast("This sample uses an older format. Start a new recording to train My rhythm.")
            return
        }
        model.settings.mode = .personal
        model.showToast("Sample saved. My rhythm is active using your recent \(mode.rawValue) samples.")
        reset(changePassage: true)
    }
}

private struct MetricRow: View {
    let label: String
    let help: String
    let value: String
    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label).font(.system(size: 10)).foregroundStyle(TyperTheme.mutedStrong)
            HelpTip(title: label, text: help)
            Spacer()
            Text(value).font(.system(size: 10, weight: .medium, design: .monospaced)).foregroundStyle(TyperTheme.ink)
        }
        .padding(.vertical, 12)
        .overlay(alignment: .bottom) { Rectangle().fill(TyperTheme.softLine).frame(height: 1) }
    }
}
