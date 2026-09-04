import Foundation

enum TypingEngine {
    private static let neighbors: [Character: [Character]] = [
        "q": Array("wa"), "w": Array("qase"), "e": Array("wsdr"), "r": Array("edft"), "t": Array("rfgy"),
        "y": Array("tghu"), "u": Array("yhji"), "i": Array("ujko"), "o": Array("iklp"), "p": Array("ol"),
        "a": Array("qwsz"), "s": Array("awedxz"), "d": Array("serfcx"), "f": Array("drtgcv"), "g": Array("ftyhbv"),
        "h": Array("gyujnb"), "j": Array("huikmn"), "k": Array("jiolm"), "l": Array("kop"), "z": Array("asx"),
        "x": Array("zsdc"), "c": Array("xdfv"), "v": Array("cfgb"), "b": Array("vghn"), "n": Array("bhjm"), "m": Array("njk")
    ]

    private static let commonConfusions: [String: String] = [
        "their": "there", "there": "their", "then": "than", "than": "then", "your": "youre", "you're": "your",
        "its": "it's", "it's": "its", "definitely": "definately", "receive": "recieve", "separate": "seperate",
        "because": "becuase", "about": "abotu", "with": "wiht", "from": "form", "that": "taht", "just": "jsut", "really": "realy"
    ]

    static func median(_ values: [Double]) -> Double {
        guard !values.isEmpty else { return 0 }
        let values = values.sorted()
        let middle = values.count / 2
        return values.count.isMultiple(of: 2) ? (values[middle - 1] + values[middle]) / 2 : values[middle]
    }

    static func mad(_ values: [Double]) -> Double {
        let center = median(values)
        return median(values.map { abs($0 - center) })
    }

    static func summarize(records: [TrainingKeyRecord], target: String, duration: Double) -> TrainingSample {
        let characters = records.filter { $0.kind == .character }
        let intervals = zip(characters, characters.dropFirst()).compactMap { prior, current -> Double? in
            let delta = current.pressTime - prior.pressTime
            return delta > 15 && delta < 2_500 ? delta : nil
        }
        var digraphs: [String: [Double]] = [:]
        var wordPauses: [Double] = []
        var punctuationPauses: [Double] = []
        for (prior, current) in zip(characters, characters.dropFirst()) {
            let delta = current.pressTime - prior.pressTime
            guard delta > 15 && delta < 5_000 else { continue }
            let pair = (prior.key + current.key).lowercased()
            digraphs[pair, default: []].append(delta)
            if prior.key.rangeOfCharacter(from: .whitespacesAndNewlines) != nil, delta < 2_500 { wordPauses.append(delta) }
            if prior.key.rangeOfCharacter(from: CharacterSet(charactersIn: ".!?,;:")) != nil { punctuationPauses.append(delta) }
        }

        let backspaces = records.filter { $0.kind == .backspace }
        let repairs = backspaces.compactMap(\.sinceMistake).filter { $0 > 0 && $0 < 10_000 }
        let dwells = characters.compactMap(\.dwell).filter { $0 > 10 && $0 < 500 }
        var burstSizes: [Double] = []
        var currentBurst = 0
        for (index, record) in characters.enumerated() {
            if index == 0 || record.pressTime - characters[index - 1].pressTime < 310 {
                currentBurst += 1
            } else {
                if currentBurst > 0 { burstSizes.append(Double(currentBurst)) }
                currentBurst = 1
            }
        }
        if currentBurst > 0 { burstSizes.append(Double(currentBurst)) }

        var confusions: [String: [String]] = [:]
        for record in characters where !record.expected.isEmpty && record.key.lowercased() != record.expected.lowercased() {
            confusions[record.expected.lowercased(), default: []].append(record.key.lowercased())
        }

        var detectionRuns: [Double] = []
        var lastMistakeIndex: Int?
        for (index, record) in records.enumerated() {
            if record.kind == .character && !record.expected.isEmpty && record.key != record.expected { lastMistakeIndex = index }
            if record.kind == .backspace, let mistake = lastMistakeIndex {
                let typedPast = records[mistake..<index].filter { $0.kind == .character }.count - 1
                detectionRuns.append(Double(max(0, typedPast)))
                lastMistakeIndex = nil
            }
        }

        let baseInterval = median(intervals)
        let minutes = max(duration / 60_000, 1 / 60)
        let speed = (Double(min(target.count, characters.count)) / 5) / minutes
        return TrainingSample(
            wpm: speed,
            medianInterval: baseInterval > 0 ? baseInterval : 188,
            intervalMAD: mad(intervals) > 0 ? mad(intervals) : 42,
            dwellMedian: median(dwells) > 0 ? median(dwells) : 76,
            dwellMAD: mad(dwells) > 0 ? mad(dwells) : 15,
            backspaceRate: Double(backspaces.count) / Double(max(1, records.count)),
            repairDelay: median(repairs) > 0 ? median(repairs) : 410,
            detectionCharacters: median(detectionRuns) > 0 ? median(detectionRuns) : 1.4,
            burstLength: median(burstSizes) > 0 ? median(burstSizes) : 7,
            punctuationPause: median(punctuationPauses) > 0 ? median(punctuationPauses) : 760,
            wordPause: max(20, (median(wordPauses) > 0 ? median(wordPauses) : 246) - (baseInterval > 0 ? baseInterval : 188)),
            digraphs: digraphs,
            confusions: confusions
        )
    }

    static func merge(samples: [TrainingSample], name: String = "My rhythm", id: UUID? = nil) -> TypingProfile {
        guard !samples.isEmpty else { return .baseline() }
        func pick(_ keyPath: KeyPath<TrainingSample, Double>) -> Double { median(samples.map { $0[keyPath: keyPath] }) }
        var digraphs: [String: [Double]] = [:]
        var confusions: [String: [String]] = [:]
        for sample in samples {
            sample.digraphs.forEach { digraphs[$0.key, default: []].append(contentsOf: $0.value) }
            sample.confusions.forEach { confusions[$0.key, default: []].append(contentsOf: $0.value) }
        }
        return TypingProfile(
            id: id ?? UUID(), name: name, sampleCount: samples.count, wpm: pick(\.wpm),
            medianInterval: pick(\.medianInterval), intervalMAD: pick(\.intervalMAD),
            dwellMedian: pick(\.dwellMedian), dwellMAD: pick(\.dwellMAD), backspaceRate: pick(\.backspaceRate),
            repairDelay: pick(\.repairDelay), detectionCharacters: pick(\.detectionCharacters), burstLength: pick(\.burstLength),
            punctuationPause: pick(\.punctuationPause), wordPause: pick(\.wordPause), digraphs: digraphs,
            confusions: confusions, createdAt: Date()
        )
    }

    static func generatePlan<R: RandomNumberGenerator>(
        text: String,
        settings: TypingSettings,
        profile: TypingProfile,
        using random: inout R
    ) -> TypingPlan {
        guard !text.isEmpty else { return TypingPlan(events: [], duration: 0, repairs: 0, effectiveWPM: 0) }
        let wpm = min(180, max(20, settings.wpm))
        let realism = min(1, max(0, settings.variation))
        let base = 12_000 / wpm
        let learnedScale = base / max(40, profile.medianInterval)
        let jitter = profile.intervalMAD * learnedScale * (0.35 + realism * 0.95)
        let learnedError = profile.sampleCount > 0 ? min(0.055, max(0.004, profile.backspaceRate * 0.82)) : 0.018
        // Error frequency is its own control. Human variation only shapes timing.
        let errorRate = settings.mistakeLevel == 0 ? 0 : learnedError * (0.38 + Double(settings.mistakeLevel) * 0.31)

        var events: [PlannedEvent] = []
        var repairs = 0
        var typedCharacters = 0
        var burstRemaining = max(3, Int(profile.burstLength.rounded()))
        var priorDwell = profile.dwellMedian
        var previousCharacter = ""
        var motorDrift = 0.0

        func unit() -> Double { Double.random(in: 0..<1, using: &random) }
        func gaussian() -> Double {
            let u = max(0.000_001, 1 - unit())
            let v = 1 - unit()
            return sqrt(-2 * log(u)) * cos(2 * .pi * v)
        }
        func bounded(_ value: Double, _ low: Double, _ high: Double) -> Double { min(high, max(low, value)) }

        func cadence(for character: String) -> Double {
            let pair = (previousCharacter + character).lowercased()
            let learned = profile.digraphs[pair].map(median) ?? base
            var interval = learned * learnedScale + gaussian() * jitter
            motorDrift = motorDrift * 0.86 + gaussian() * jitter * 0.12
            interval += motorDrift
            interval *= 1 + ((burstRemaining > 0 ? 0.84 : 1.22) - 1) * realism
            burstRemaining -= 1
            if burstRemaining < 0 { burstRemaining = max(3, Int((profile.burstLength * (0.65 + unit() * 0.8)).rounded())) }
            if character.rangeOfCharacter(from: .whitespaces) != nil { interval += profile.wordPause * realism * (0.4 + unit()) }
            if character.first?.isUppercase == true && previousCharacter != "\n" { interval += (50 + unit() * 120) * realism }
            if sameFinger(previousCharacter, character) { interval += (18 + unit() * 38) * realism }
            if previousCharacter.rangeOfCharacter(from: CharacterSet(charactersIn: ",;:")) != nil { interval += (300 + unit() * 200) * realism }
            if previousCharacter.rangeOfCharacter(from: CharacterSet(charactersIn: ".!?\n")) != nil && settings.thoughtPauses {
                interval += (600 + unit() * 600) * realism
                if unit() < 0.025 { interval += 2_000 + unit() * 3_000 }
            }
            if settings.fatigueDrift && text.count > 250 { interval *= 1 + (Double(typedCharacters) / Double(text.count)) * 0.09 }
            interval *= 1 + 0.13 * exp(-Double(typedCharacters) / 11)
            let microPauseRoll = unit()
            let microPauseLength = unit()
            if microPauseRoll < 0.012 * realism { interval += 180 + microPauseLength * 520 }
            return bounded(interval, 28, 8_000)
        }

        func appendCharacter(_ character: String, speedMultiplier: Double = 1) {
            let interval = cadence(for: character) * speedMultiplier
            let dwell = bounded(profile.dwellMedian + gaussian() * profile.dwellMAD, 32, 190)
            let flight = bounded(interval - priorDwell, 8, 8_000)
            let kind: PlannedEventKind = character == "\n" ? .enter : character == "\t" ? .tab : .character
            events.append(PlannedEvent(kind: kind, value: character, flight: flight, dwell: dwell))
            previousCharacter = character
            priorDwell = dwell
            typedCharacters += 1
        }

        func appendKey(_ kind: PlannedEventKind, delay: Double) {
            let dwell = bounded(profile.dwellMedian * (0.72 + unit() * 0.3), 32, 145)
            events.append(PlannedEvent(kind: kind, flight: bounded(delay, 20, 8_000), dwell: dwell))
            priorDwell = dwell
        }

        let tokens = tokenize(text)
        var tokenIndex = 0
        while tokenIndex < tokens.count {
            let token = tokens[tokenIndex]
            guard token.rangeOfCharacter(from: .letters) != nil, token.count >= 3 else {
                token.forEach { appendCharacter(String($0)) }
                tokenIndex += 1
                continue
            }

            let lettersOnly = token.allSatisfy { $0.isLetter || $0 == "'" }
            let shouldMistake = lettersOnly && unit() < errorRate * Double(token.count)
            guard shouldMistake else {
                token.forEach { appendCharacter(String($0)) }
                tokenIndex += 1
                continue
            }

            let lower = token.lowercased()
            if let confused = commonConfusions[lower], unit() < 0.22 {
                let wrong = token.first?.isUppercase == true ? confused.prefix(1).uppercased() + confused.dropFirst() : confused
                wrong.forEach { appendCharacter(String($0)) }
                let canDelay = settings.delayedRepairs && tokenIndex + 2 < tokens.count && tokens[tokenIndex + 1].allSatisfy(\.isWhitespace) && unit() < 0.46
                if canDelay {
                    let carried = tokens[tokenIndex + 1] + tokens[tokenIndex + 2]
                    carried.forEach { appendCharacter(String($0)) }
                    for move in 0..<carried.count { appendKey(.arrowLeft, delay: move == 0 ? profile.repairDelay * (1.1 + unit()) : 30 + unit() * 24) }
                    for index in 0..<wrong.count { appendKey(.backspace, delay: index == 0 ? profile.repairDelay * (0.55 + unit()) : 36 + unit() * 34) }
                    token.forEach { appendCharacter(String($0), speedMultiplier: 0.82) }
                    for _ in 0..<carried.count { appendKey(.arrowRight, delay: 28 + unit() * 20) }
                    tokenIndex += 3
                } else {
                    for index in 0..<wrong.count { appendKey(.backspace, delay: index == 0 ? profile.repairDelay * (0.55 + unit()) : 36 + unit() * 34) }
                    token.forEach { appendCharacter(String($0), speedMultiplier: 0.82) }
                    tokenIndex += 1
                }
                repairs += 1
                continue
            }

            let characters = Array(token)
            let mistakeIndex = min(characters.count - 2, max(1, Int(unit() * Double(max(1, characters.count - 2))) + 1))
            let choice = unit()
            if choice < 0.24 && mistakeIndex + 1 < characters.count {
                for index in characters.indices {
                    if index == mistakeIndex {
                        appendCharacter(String(characters[index + 1]))
                        appendCharacter(String(characters[index]))
                        appendKey(.backspace, delay: profile.repairDelay * (0.5 + unit()))
                        appendKey(.backspace, delay: 45 + unit() * 34)
                        appendCharacter(String(characters[index]), speedMultiplier: 0.8)
                        appendCharacter(String(characters[index + 1]), speedMultiplier: 0.8)
                    } else if index != mistakeIndex + 1 {
                        appendCharacter(String(characters[index]))
                    }
                }
            } else {
                for index in characters.indices {
                    if index == mistakeIndex {
                        let intended = String(characters[index])
                        let learned = profile.confusions[intended.lowercased()] ?? []
                        let neighborChoices = neighbors[Character(intended.lowercased())] ?? []
                        let wrong: String
                        if !learned.isEmpty && unit() < 0.6 { wrong = learned[min(learned.count - 1, Int(unit() * Double(learned.count)))] }
                        else if let adjacent = neighborChoices.randomElement(using: &random) { wrong = String(adjacent) }
                        else { wrong = intended }
                        appendCharacter(wrong)
                        if choice > 0.82 { appendCharacter(wrong) }
                        let detectionExtra = Int(max(0, min(2, profile.detectionCharacters.rounded())))
                        if settings.delayedRepairs && detectionExtra > 0 && index + detectionExtra < characters.count && unit() < 0.34 {
                            for lookahead in 1...detectionExtra { appendCharacter(String(characters[index + lookahead])) }
                            for _ in 0..<detectionExtra { appendKey(.backspace, delay: profile.repairDelay * 0.45) }
                        }
                        appendKey(.backspace, delay: profile.repairDelay * (0.5 + unit()))
                        if choice > 0.82 { appendKey(.backspace, delay: 42 + unit() * 30) }
                        appendCharacter(intended, speedMultiplier: 0.8)
                        if settings.delayedRepairs && detectionExtra > 0 && index + detectionExtra < characters.count {
                            // Lookahead characters were removed above and will be emitted by the normal loop.
                        }
                    } else {
                        appendCharacter(String(characters[index]))
                    }
                }
            }
            repairs += 1
            tokenIndex += 1
        }

        let duration = events.reduce(0) { $0 + $1.flight + $1.dwell }
        let effective = Int(((Double(text.count) / 5) / max(duration / 60_000, 0.001)).rounded())
        return TypingPlan(events: events, duration: duration, repairs: repairs, effectiveWPM: effective)
    }

    static func generatePlan(text: String, settings: TypingSettings, profile: TypingProfile) -> TypingPlan {
        var generator = SystemRandomNumberGenerator()
        return generatePlan(text: text, settings: settings, profile: profile, using: &generator)
    }

    private static func tokenize(_ text: String) -> [String] {
        guard let expression = try? NSRegularExpression(pattern: "\\s+|\\S+") else { return [text] }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return expression.matches(in: text, range: range).compactMap { match in
            Range(match.range, in: text).map { String(text[$0]) }
        }
    }

    private static func sameFinger(_ lhs: String, _ rhs: String) -> Bool {
        let columns = ["qaz", "wsx", "edc", "rfvtgb", "yhnujm", "ik", "ol", "p"]
        guard let left = lhs.lowercased().first, let right = rhs.lowercased().first else { return false }
        return columns.contains { $0.contains(left) && $0.contains(right) }
    }
}
