import Foundation

enum AppSection: String, CaseIterable, Identifiable {
    case compose = "Compose"
    case train = "Train"
    case profiles = "Profiles"
    var id: String { rawValue }
}

enum SettingsSection: String, CaseIterable, Identifiable {
    case general = "General"
    case guide = "Guide"
    var id: String { rawValue }
}

enum TrainingMode: String, Codable, CaseIterable, Identifiable {
    case copy = "Copy"
    case freewrite = "Freewrite"
    case sprint = "Sprint"
    case liveCapture = "Live capture"

    var id: String { rawValue }

    var description: String {
        switch self {
        case .copy: return "Learns errors, substitutions, and exact digraph timing."
        case .freewrite: return "Learns thought pauses and your natural composition rhythm."
        case .sprint: return "Learns your fast bursts, shortest dwell, and correction reflex."
        case .liveCapture: return "Learns from normal writing in another app without delaying its keystrokes."
        }
    }

    var instruction: String {
        switch self {
        case .copy: return "Copy the passage exactly. Correct real mistakes normally—do not invent mistakes for the test."
        case .freewrite: return "Write fresh thoughts directly in the box. Pause, revise, and backspace naturally; do not paste polished text."
        case .sprint: return "Copy the prompt quickly. Keep moving, but still correct mistakes using your normal reflexes."
        case .liveCapture: return "Start a private session, switch to Google Docs or another editor, then type normally. Return here to stop and save."
        }
    }
}

enum RunState: Equatable {
    case ready
    case preparing
    case armed(Int)
    case typing
    case paused
    case complete
    case stopped
    case error(String)

    var label: String {
        switch self {
        case .ready: return "Ready"
        case .preparing: return "Preparing"
        case .armed(let count): return "Armed · \(count)"
        case .typing: return "Typing"
        case .paused: return "Paused"
        case .complete: return "Complete"
        case .stopped: return "Stopped"
        case .error: return "Needs attention"
        }
    }

    var isPlaybackActive: Bool { self == .typing || self == .paused }
    var isBusy: Bool {
        switch self { case .preparing, .armed, .typing, .paused: return true; default: return false }
    }
}

struct TypingSettings: Codable, Equatable {
    enum Mode: String, Codable, CaseIterable, Identifiable {
        case personal = "My rhythm"
        case natural = "Natural"
        case clean = "Clean"
        var id: String { rawValue }
    }

    var mode: Mode = .natural
    var wpm: Double = 64
    var variation: Double = 0.78
    var mistakeLevel: Int = 2
    var delayedRepairs = true
    var thoughtPauses = true
    var extendedThoughtPauses = false
    var sentencePauses = false
    var sentencePauseMinimum = 2
    var sentencePauseMaximum = 10
    var learnedPauses = true
    var showTypingOverlay = true
    var fatigueDrift = true

    var sentencePauseSeconds: ClosedRange<Int> {
        let first = min(60, max(1, sentencePauseMinimum))
        let second = min(60, max(1, sentencePauseMaximum))
        return min(first, second)...max(first, second)
    }

    init() {}

    private enum CodingKeys: String, CodingKey {
        case mode, wpm, variation, mistakeLevel, delayedRepairs, thoughtPauses, extendedThoughtPauses
        case sentencePauses, sentencePauseMinimum, sentencePauseMaximum, fatigueDrift, learnedPauses, showTypingOverlay
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        mode = try values.decodeIfPresent(Mode.self, forKey: .mode) ?? .natural
        wpm = try values.decodeIfPresent(Double.self, forKey: .wpm) ?? 64
        variation = try values.decodeIfPresent(Double.self, forKey: .variation) ?? 0.78
        mistakeLevel = try values.decodeIfPresent(Int.self, forKey: .mistakeLevel) ?? 2
        delayedRepairs = try values.decodeIfPresent(Bool.self, forKey: .delayedRepairs) ?? true
        thoughtPauses = try values.decodeIfPresent(Bool.self, forKey: .thoughtPauses) ?? true
        extendedThoughtPauses = try values.decodeIfPresent(Bool.self, forKey: .extendedThoughtPauses) ?? false
        sentencePauses = try values.decodeIfPresent(Bool.self, forKey: .sentencePauses) ?? false
        sentencePauseMinimum = try values.decodeIfPresent(Int.self, forKey: .sentencePauseMinimum) ?? 2
        sentencePauseMaximum = try values.decodeIfPresent(Int.self, forKey: .sentencePauseMaximum) ?? 10
        learnedPauses = try values.decodeIfPresent(Bool.self, forKey: .learnedPauses) ?? true
        showTypingOverlay = try values.decodeIfPresent(Bool.self, forKey: .showTypingOverlay) ?? true
        fatigueDrift = try values.decodeIfPresent(Bool.self, forKey: .fatigueDrift) ?? true
    }
}

struct TypingProfile: Codable, Identifiable, Equatable {
    var id: UUID
    var name: String
    var sampleCount: Int
    var wpm: Double
    var medianInterval: Double
    var intervalMAD: Double
    var dwellMedian: Double
    var dwellMAD: Double
    var backspaceRate: Double
    var repairDelay: Double
    var detectionCharacters: Double
    var burstLength: Double
    var punctuationPause: Double
    var wordPause: Double
    var digraphs: [String: [Double]]
    var confusions: [String: [String]]
    var createdAt: Date
    // Optional additions preserve decoding of every v1 profile.
    var evidence: TimingEvidence? = nil
    var trainingMode: TrainingMode? = nil

    var isLegacy: Bool {
        id != Self.baselineID && sampleCount > 0 && evidence == nil
    }

    static let baselineID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!

    static func baseline(wpm: Double = 64) -> TypingProfile {
        let interval = 12_000 / wpm
        return TypingProfile(
            id: baselineID,
            name: "Baseline",
            sampleCount: 0,
            wpm: wpm,
            medianInterval: interval,
            intervalMAD: interval * 0.24,
            dwellMedian: 76,
            dwellMAD: 15,
            backspaceRate: 0.022,
            repairDelay: 390,
            detectionCharacters: 1.4,
            burstLength: 7.2,
            punctuationPause: 760,
            wordPause: 58,
            digraphs: [
                "th": [126, 132, 119], "he": [128, 135, 121], "in": [142, 151],
                "er": [145, 154], "qu": [220, 238], "ed": [205, 216], "de": [196, 210]
            ],
            confusions: [:],
            createdAt: Date()
        )
    }
}

enum PlannedEventKind: String, Codable {
    case character
    case backspace
    case wordBackspace
    case arrowLeft
    case arrowRight
    case shiftArrowLeft
    case enter
    case tab
}

struct PlannedEvent: Codable, Equatable {
    var kind: PlannedEventKind
    var value: String = ""
    /// Signed prior-key-release to this key press, in milliseconds.
    var flight: Double
    var dwell: Double
    var pauseKind: PlannedPauseKind? = nil
}

enum PlannedPauseKind: String, Codable {
    case sentence = "Sentence pause"
    case thought = "Thought pause"
    case extendedThought = "Extended thought pause"
    case learned = "Learned pause"
    case hesitation = "Hesitation"
    case repair = "Correction"
}

struct PlaybackProgress: Equatable {
    var fraction: Double = 0
    var remaining: Double = 0
    var waitRemaining: Double = 0
    var pauseKind: PlannedPauseKind?
    var isPaused = false
    var canSkipWait: Bool { !isPaused && pauseKind != nil && waitRemaining > 0 }
    var activity: String {
        if isPaused { return "Paused" }
        if let pauseKind, waitRemaining > 0 { return "\(pauseKind.rawValue) · \(String(format: "%.1f", waitRemaining)) s" }
        return "Typing"
    }
}

struct TypingPlan: Codable, Equatable {
    var events: [PlannedEvent]
    var duration: Double
    var repairs: Int
    var effectiveWPM: Int
}

struct TrainingKeyRecord: Codable, Equatable {
    enum Kind: String, Codable { case character, backspace, wordDelete, selection, navigation, boundary }
    var id: UUID
    var kind: Kind
    var key: String
    var expected: String
    var pressTime: Double
    var dwell: Double?
    var cursor: Int
    var sinceMistake: Double?
}

struct TrainingSample: Codable, Equatable {
    var wpm: Double
    var medianInterval: Double
    var intervalMAD: Double
    var dwellMedian: Double
    var dwellMAD: Double
    var backspaceRate: Double
    var repairDelay: Double
    var detectionCharacters: Double
    var burstLength: Double
    var punctuationPause: Double
    var wordPause: Double
    var digraphs: [String: [Double]]
    var confusions: [String: [String]]
    var evidence: TimingEvidence? = nil
    var mode: TrainingMode? = nil
    var capturedAt: Date? = nil
    // Only the built-in Copy/Sprint reference prompt, never captured Live text.
    var referenceText: String? = nil
    // Nil means the older recording did not verify passage completion.
    // This does not make an otherwise current sample Legacy.
    var referenceCompleted: Bool? = nil

    var isLegacy: Bool { evidence == nil || mode == nil }
}
