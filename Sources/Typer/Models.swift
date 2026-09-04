import Foundation

enum AppSection: String, CaseIterable, Identifiable {
    case compose = "Compose"
    case train = "Train"
    case profiles = "Profiles"
    var id: String { rawValue }
}

enum TrainingMode: String, CaseIterable, Identifiable {
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
    case complete
    case stopped
    case error(String)

    var label: String {
        switch self {
        case .ready: return "Ready"
        case .preparing: return "Preparing"
        case .armed(let count): return "Armed · \(count)"
        case .typing: return "Typing"
        case .complete: return "Complete"
        case .stopped: return "Stopped"
        case .error: return "Needs attention"
        }
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
    var fatigueDrift = true
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
    case arrowLeft
    case arrowRight
    case shiftArrowLeft
    case enter
    case tab
}

struct PlannedEvent: Codable, Equatable {
    var kind: PlannedEventKind
    var value: String = ""
    var flight: Double
    var dwell: Double
}

struct TypingPlan: Codable, Equatable {
    var events: [PlannedEvent]
    var duration: Double
    var repairs: Int
    var effectiveWPM: Int
}

struct TrainingKeyRecord: Codable, Equatable {
    enum Kind: String, Codable { case character, backspace }
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
}
