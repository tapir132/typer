import SwiftUI

struct TrainingView: View {
    private enum TrainingMode: String, CaseIterable, Identifiable {
        case copy = "Copy"
        case freewrite = "Freewrite"
        case sprint = "Sprint"
        var id: String { rawValue }
        var description: String {
            switch self {
            case .copy: return "Learns errors, substitutions, and exact digraph timing."
            case .freewrite: return "Learns thought pauses and your natural composition rhythm."
            case .sprint: return "Learns your fast bursts, shortest dwell, and correction reflex."
            }
        }
    }

    @ObservedObject var model: AppModel
    @ObservedObject private var profiles: ProfileStore
    @State private var mode: TrainingMode = .copy
    @State private var passageIndex = 0
    @State private var input = ""
    @State private var records: [TrainingKeyRecord] = []
    @State private var startedAt: Double?
    @State private var lastMistakeAt: Double?
    @State private var activePresses: [UInt16: UUID] = [:]

    private let passages = [
        "The tiny bookstore stayed open after midnight, its windows glowing against the rain. I stepped inside for five minutes and left an hour later with three novels and a new favorite place.",
        "We shipped the rough version on Friday afternoon. By Monday, people were using it in ways we had never considered, which was both terrifying and exactly what we hoped would happen.",
        "A good tool disappears while you use it. The controls feel obvious, the feedback arrives at the right moment, and the difficult work starts to feel strangely effortless.",
        "When the train crossed the bridge, every window caught the last orange light. For a few seconds, the whole carriage went quiet and watched the city appear below."
    ]

    init(model: AppModel) {
        self.model = model
        profiles = model.profiles
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 7) {
                    Text("Teach it your rhythm.").font(.system(size: 27, weight: .semibold)).tracking(-0.5)
                    Text("Type naturally—correct mistakes, pause, and change your mind like you normally would.").font(.system(size: 13)).foregroundStyle(TyperTheme.mutedStrong)
                }
                Spacer()
                HStack(alignment: .firstTextBaseline, spacing: 9) {
                    Text("\(min(profiles.samples.count, 3)) / 3").font(.system(size: 19, weight: .semibold, design: .monospaced)).foregroundStyle(TyperTheme.signal)
                    Text("samples\nrecorded").font(.system(size: 9)).foregroundStyle(TyperTheme.muted)
                }
            }
            .padding(.bottom, 24)

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
        .padding(.horizontal, 48)
        .padding(.top, 34)
        .padding(.bottom, 34)
        .onChange(of: mode) { _, _ in reset(changePassage: false) }
    }

    private var trainingStage: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Picker("Training mode", selection: $mode) {
                    ForEach(TrainingMode.allCases) { mode in Text(mode.rawValue).tag(mode) }
                }
                .labelsHidden().pickerStyle(.segmented).frame(width: 310)
                Spacer()
                if mode != .freewrite {
                    Button("Try another passage") { reset(changePassage: true) }.buttonStyle(QuietButtonStyle())
                }
            }
            .frame(height: 58)

            Text(mode.description).font(.system(size: 10)).foregroundStyle(TyperTheme.muted).padding(.bottom, 20)

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
                Button("Save sample") { saveSample() }.buttonStyle(SecondaryButtonStyle()).disabled(!canSave)
            }
            .padding(.top, 11)
        }
    }

    private var fingerprint: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Live fingerprint").font(.system(size: 12, weight: .semibold))
                Spacer()
                HStack(spacing: 5) { Circle().fill(TyperTheme.signal).frame(width: 5, height: 5); Text("listening") }
                    .font(.system(size: 8, weight: .medium, design: .monospaced)).foregroundStyle(TyperTheme.signal)
                    .padding(.horizontal, 7).padding(.vertical, 5).background(TyperTheme.signal.opacity(0.09)).clipShape(Capsule())
            }
            .frame(height: 58)

            MetricRow(label: "Speed", value: sample.map { "\(Int($0.wpm.rounded())) WPM" } ?? "—")
            MetricRow(label: "Dwell time", value: sample.map { "\(Int($0.dwellMedian.rounded())) ms" } ?? "—")
            MetricRow(label: "Flight time", value: sample.map { "\(Int(max(0, $0.medianInterval - $0.dwellMedian).rounded())) ms" } ?? "—")
            MetricRow(label: "Digraph jitter", value: sample.map { "±\(Int($0.intervalMAD.rounded())) ms" } ?? "—")
            MetricRow(label: "Corrections", value: sample.map { "\(Int(($0.backspaceRate * 100).rounded()))%" } ?? "—")
            MetricRow(label: "Detection delay", value: sample.map { "\($0.detectionCharacters.formatted(.number.precision(.fractionLength(1)))) keys" } ?? "—")
            MetricRow(label: "Burst length", value: sample.map { "\($0.burstLength.formatted(.number.precision(.fractionLength(1)))) keys" } ?? "—")

            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "lock.fill").foregroundStyle(TyperTheme.signal).font(.system(size: 10)).padding(.top, 1)
                Text("Stored on this Mac. Raw samples never leave the app.")
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
        }
    }

    private var target: String { mode == .freewrite ? input : prompt }
    private var elapsed: Double { max(1, (records.last?.pressTime ?? startedAt ?? 0) - (startedAt ?? 0)) }
    private var sample: TrainingSample? {
        guard records.filter({ $0.kind == .character }).count >= 2 else { return nil }
        return TypingEngine.summarize(records: records, target: target, duration: elapsed)
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
        guard !event.isRepeat else { return }
        if startedAt == nil { startedAt = event.timestamp }
        let expected = mode == .freewrite ? "" : character(atUTF16Offset: event.cursor, in: prompt)
        let record: TrainingKeyRecord
        if event.keyCode == 51 {
            record = TrainingKeyRecord(id: UUID(), kind: .backspace, key: "Backspace", expected: "", pressTime: event.timestamp, cursor: event.cursor, sinceMistake: lastMistakeAt.map { event.timestamp - $0 })
        } else if event.characters.count == 1 {
            let id = UUID()
            record = TrainingKeyRecord(id: id, kind: .character, key: event.characters, expected: expected, pressTime: event.timestamp, cursor: event.cursor)
            activePresses[event.keyCode] = id
            if !expected.isEmpty && event.characters != expected { lastMistakeAt = event.timestamp }
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

    private func saveSample() {
        guard let sample else { return }
        profiles.add(sample: sample)
        model.settings.mode = .personal
        model.showToast(profiles.samples.count >= 3 ? "Personal profile ready and active." : "Sample saved. Three modes make the strongest profile.")
        reset(changePassage: true)
    }
}

private struct MetricRow: View {
    let label: String
    let value: String
    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label).font(.system(size: 10)).foregroundStyle(TyperTheme.mutedStrong)
            Spacer()
            Text(value).font(.system(size: 10, weight: .medium, design: .monospaced)).foregroundStyle(TyperTheme.ink)
        }
        .padding(.vertical, 12)
        .overlay(alignment: .bottom) { Rectangle().fill(TyperTheme.softLine).frame(height: 1) }
    }
}
