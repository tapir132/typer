import Foundation

extension TypingProfile {
    /// Keeps short or noisy training sessions from overpowering the baseline.
    /// New profiles use valid observations; legacy summaries retain cautious fallback.
    func stabilized(wpm targetWPM: Double) -> TypingProfile {
        let baseline = TypingProfile.baseline(wpm: targetWPM)
        guard sampleCount > 0 else { return baseline }
        let observed = Double(evidence?.pairs.count ?? 0)
        let confidence = evidence == nil ? min(0.45, 0.12 + Double(sampleCount) * 0.06) : min(0.95, observed / (observed + 120))
        func blend(_ learned: Double, _ reference: Double, range: ClosedRange<Double>, observations: Int? = nil) -> Double {
            let safe = learned.isFinite ? min(range.upperBound, max(range.lowerBound, learned)) : reference
            let n = Double(max(0, observations ?? 0))
            let weight = observations == nil ? confidence : min(confidence, n / (n + 24))
            return reference + (safe - reference) * weight
        }

        var stableDigraphs = baseline.digraphs
        for (pair, values) in digraphs where !values.isEmpty {
            let reference = baseline.digraphs[pair].map(TypingEngine.median) ?? baseline.medianInterval
            let valid = values.filter { $0.isFinite && (15...800).contains($0) }
            let weight = min(confidence, Double(valid.count) / Double(valid.count + 24))
            if !valid.isEmpty { stableDigraphs[pair] = boundedSample(valid, limit: 64).map { reference + ($0 - reference) * weight } }
        }

        return TypingProfile(
            id: id,
            name: name,
            sampleCount: sampleCount,
            wpm: blend(wpm, baseline.wpm, range: 20...180),
            medianInterval: blend(medianInterval, baseline.medianInterval, range: 55...600),
            intervalMAD: blend(intervalMAD, baseline.intervalMAD, range: 8...220),
            dwellMedian: blend(dwellMedian, baseline.dwellMedian, range: 35...150, observations: evidence?.dwells.count),
            dwellMAD: blend(dwellMAD, baseline.dwellMAD, range: 4...65, observations: evidence?.dwells.count),
            backspaceRate: blend(backspaceRate, baseline.backspaceRate, range: 0.002...0.08),
            repairDelay: blend(repairDelay, baseline.repairDelay, range: 120...1_800, observations: evidence?.repairLatencies.count),
            detectionCharacters: blend(detectionCharacters, baseline.detectionCharacters, range: 0...8, observations: evidence?.detectionDistances.count),
            burstLength: blend(burstLength, baseline.burstLength, range: 3...18, observations: evidence?.burstLengths.count),
            punctuationPause: blend(punctuationPause, baseline.punctuationPause, range: 300...1_600, observations: evidence?.pauses.count),
            wordPause: blend(wordPause, baseline.wordPause, range: 20...250),
            digraphs: stableDigraphs,
            confusions: confusions,
            createdAt: createdAt,
            evidence: evidence
        )
    }
}

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

    static func summarize(records: [TrainingKeyRecord], target: String, duration: Double, mode: TrainingMode? = nil) -> TrainingSample {
        let evidence = TimingEvidence.extract(records)
        let characters = records.filter { $0.kind == .character }
        let intervals = zip(records, records.dropFirst()).compactMap { prior, current -> Double? in
            guard prior.kind == .character, current.kind == .character else { return nil }
            let delta = current.pressTime - prior.pressTime
            return delta.isFinite && (15...2_500).contains(delta) ? delta : nil
        }
        let center = intervals.isEmpty ? 188 : median(intervals)
        var wordPauses: [Double] = [], punctuationPauses: [Double] = []
        for (prior, current) in zip(records, records.dropFirst()) where prior.kind == .character && current.kind == .character {
            let delta = current.pressTime - prior.pressTime
            guard delta.isFinite && (15...5_000).contains(delta) else { continue }
            if prior.key.first?.isWhitespace == true { wordPauses.append(delta) }
            if prior.key.rangeOfCharacter(from: CharacterSet(charactersIn: ".!?,;:")) != nil { punctuationPauses.append(delta) }
        }
        var confusions: [String: [String]] = [:]
        for record in characters where !record.expected.isEmpty && record.key.lowercased() != record.expected.lowercased() {
            guard record.expected.count == 1, record.key.count == 1 else { continue }
            confusions[record.expected.lowercased(), default: []].append(record.key.lowercased())
        }
        confusions = confusions.mapValues { boundedSample($0, limit: 32) }
        let backspaces = records.filter { $0.kind == .backspace || $0.kind == .wordDelete }
        let detectionLatency = backspaces.compactMap(\.sinceMistake).filter { $0.isFinite && (1...10_000).contains($0) }
        let repair = detectionLatency.isEmpty ? evidence.repairLatencies : detectionLatency
        let minutes = max(duration.isFinite ? duration / 60_000 : 1, 1 / 60)
        return TrainingSample(
            wpm: (Double(min(target.count, characters.count)) / 5) / minutes,
            medianInterval: center, intervalMAD: intervals.isEmpty ? 42 : mad(intervals),
            dwellMedian: evidence.dwells.isEmpty ? 76 : median(evidence.dwells),
            dwellMAD: evidence.dwells.isEmpty ? 15 : mad(evidence.dwells),
            backspaceRate: Double(backspaces.count) / Double(max(1, characters.count)),
            repairDelay: repair.isEmpty ? 410 : median(repair),
            detectionCharacters: evidence.detectionDistances.isEmpty ? 1.4 : median(evidence.detectionDistances),
            burstLength: evidence.burstLengths.isEmpty ? 7 : median(evidence.burstLengths),
            punctuationPause: punctuationPauses.isEmpty ? 760 : median(punctuationPauses),
            wordPause: max(20, (wordPauses.isEmpty ? 246 : median(wordPauses)) - center),
            digraphs: evidence.digraphPairs.mapValues { $0.values.map(\.interval) }, confusions: confusions,
            evidence: evidence, mode: mode, capturedAt: Date(), referenceText: mode == .copy || mode == .sprint ? target : nil
        )
    }

    static func merge(samples: [TrainingSample], name: String = "My rhythm", id: UUID? = nil) -> TypingProfile {
        guard !samples.isEmpty else { return .baseline() }
        func pick(_ keyPath: KeyPath<TrainingSample, Double>) -> Double {
            let observations = samples.filter { $0[keyPath: keyPath].isFinite }.sorted { $0[keyPath: keyPath] < $1[keyPath: keyPath] }
            func weight(_ sample: TrainingSample) -> Double { Double(min(128, max(1, sample.evidence?.pairs.count ?? 16))) }
            let total = observations.reduce(0) { $0 + weight($1) }
            var cumulative = 0.0
            for sample in observations {
                cumulative += weight(sample)
                if cumulative >= total / 2 { return sample[keyPath: keyPath] }
            }
            return 0
        }
        let evidenceSamples = samples.compactMap(\.evidence)
        let evidence = evidenceSamples.isEmpty ? nil : TimingEvidence.merge(evidenceSamples)
        var digraphs: [String: [Double]] = [:]
        var confusions: [String: [String]] = [:]
        for sample in samples {
            sample.digraphs.forEach { digraphs[$0.key, default: []].append(contentsOf: $0.value) }
            sample.confusions.forEach { confusions[$0.key, default: []].append(contentsOf: $0.value) }
        }
        digraphs = digraphs.mapValues { boundedSample($0.filter { $0.isFinite && (15...2_500).contains($0) }, limit: 64) }
        confusions = confusions.mapValues { boundedSample($0, limit: 64) }
        return TypingProfile(
            id: id ?? UUID(), name: name, sampleCount: samples.count, wpm: pick(\.wpm),
            medianInterval: pick(\.medianInterval), intervalMAD: pick(\.intervalMAD),
            dwellMedian: pick(\.dwellMedian), dwellMAD: pick(\.dwellMAD), backspaceRate: pick(\.backspaceRate),
            repairDelay: pick(\.repairDelay), detectionCharacters: pick(\.detectionCharacters), burstLength: pick(\.burstLength),
            punctuationPause: pick(\.punctuationPause), wordPause: pick(\.wordPause), digraphs: digraphs,
            confusions: confusions, createdAt: Date(), evidence: evidence
        )
    }

    static func generatePlan<R: RandomNumberGenerator>(
        text: String,
        settings: TypingSettings,
        profile: TypingProfile,
        using random: inout R
    ) -> TypingPlan {
        guard !text.isEmpty else { return TypingPlan(events: [], duration: 0, repairs: 0, effectiveWPM: 0) }
        let sourceCharacterCount = text.count
        let wpm = settings.wpm.isFinite ? min(180, max(20, settings.wpm)) : 64
        let profile = profile.stabilized(wpm: wpm)
        let realism = settings.variation.isFinite ? min(1, max(0, settings.variation)) : 0.78
        let base = 12_000 / wpm
        let evidence = profile.evidence
        let baselineDigraphs = TypingProfile.baseline().digraphs
        let empiricalCenter = median(evidence?.pairs.values.filter(\.isValid).map(\.interval) ?? [])
        let learnedScale = base / max(40, empiricalCenter > 0 ? empiricalCenter : profile.medianInterval)
        let pooled = PairDistribution(evidence?.pairs.values ?? [], count: evidence?.pairs.count)
        let transitions = evidence?.transitions.mapValues { PairDistribution($0.values, count: $0.count) } ?? [:]
        let exactPairs = evidence?.digraphPairs.mapValues { PairDistribution($0.values, count: $0.count) } ?? [:]
        let learnedError = profile.sampleCount > 0 ? min(0.055, max(0.004, profile.backspaceRate * 0.82)) : 0.018
        // Error frequency is its own control. Human variation only shapes timing.
        let errorRate = settings.mode == .clean || settings.mistakeLevel == 0 ? 0 : learnedError * (0.38 + Double(settings.mistakeLevel) * 0.31)

        var events: [PlannedEvent] = []
        events.reserveCapacity(sourceCharacterCount + max(16, sourceCharacterCount / 20))
        var repairs = 0
        var typedCharacters = 0
        var burstRemaining = max(3, Int(profile.burstLength.rounded()))
        var previousCharacter = ""
        var motorDrift = 0.0

        func unit() -> Double { Double.random(in: 0..<1, using: &random) }
        func gaussian() -> Double {
            let u = max(0.000_001, 1 - unit())
            let v = 1 - unit()
            return sqrt(-2 * log(u)) * cos(2 * .pi * v)
        }
        func bounded(_ value: Double, _ low: Double, _ high: Double) -> Double { min(high, max(low, value)) }

        func sampled(_ distribution: PairDistribution?, parent: TimingPair, pseudocount: Double) -> TimingPair {
            let draw = unit() // A fixed draw count keeps mistake choices independent of variation.
            guard let distribution, !distribution.values.isEmpty else { return parent }
            let value = distribution.values[min(distribution.values.count - 1, Int(draw * Double(distribution.values.count)))]
            let n = Double(min(2_000, max(0, distribution.count)))
            let weight = min(0.95, n / (n + pseudocount))
            return TimingPair(interval: parent.interval + (value.interval * learnedScale - parent.interval) * weight,
                              priorDwell: parent.priorDwell + (value.priorDwell - parent.priorDwell) * weight)
        }

        func cadence(for character: String) -> TimingPair {
            let pair = KeyboardTransition.digraph(previousCharacter, character) ?? ""
            let transition = KeyboardTransition.classify(previousCharacter, character)
            let factor = transition == "sameFinger" ? 1.16 : transition == "sameHand" ? 1.04 : 0.96
            let reference: Double
            if evidence == nil, profile.sampleCount > 0, let legacy = profile.digraphs[pair], !legacy.isEmpty {
                reference = median(legacy) / max(40, profile.medianInterval)
            } else { reference = baselineDigraphs[pair].map(median).map { $0 / 187.5 } ?? factor }
            // Log-normal positive marginals; no fitted population parameters are claimed.
            let sigma = 0.16 + realism * 0.42
            var timing = TimingPair(interval: base * reference * exp(gaussian() * sigma),
                                    priorDwell: profile.dwellMedian * exp(gaussian() * (0.08 + realism * 0.22)))
            timing = sampled(pooled, parent: timing, pseudocount: 120)
            timing = sampled(transitions[transition], parent: timing, pseudocount: 48)
            timing = sampled(exactPairs[pair], parent: timing, pseudocount: 24)
            motorDrift = motorDrift * 0.86 + gaussian() * 0.025 * realism
            var interval = timing.interval * exp(motorDrift)
            interval *= 1 + ((burstRemaining > 0 ? 0.90 : 1.16) - 1) * realism
            burstRemaining -= 1
            if burstRemaining < 0 { burstRemaining = max(3, Int((profile.burstLength * (0.65 + unit() * 0.8)).rounded())) }
            let boundaryConfidence = exactPairs[pair]?.confidence ?? 0
            let boundaryScale = realism * (1 - boundaryConfidence)
            if previousCharacter.first?.isWhitespace == true { interval += profile.wordPause * boundaryScale * (0.4 + unit()) }
            if character.first?.isUppercase == true && previousCharacter != "\n" { interval += (30 + unit() * 80) * boundaryScale }
            if previousCharacter.rangeOfCharacter(from: CharacterSet(charactersIn: ",;:")) != nil { interval += (260 + unit() * 180) * boundaryScale }
            if previousCharacter.rangeOfCharacter(from: CharacterSet(charactersIn: ".!?\n")) != nil && settings.thoughtPauses {
                interval += (500 + unit() * 500) * boundaryScale
                if unit() < 0.025 {
                    let pauseRoll = unit()
                    interval += settings.extendedThoughtPauses ? 2_000 + pow(pauseRoll, 1.8) * 43_000 : 2_000 + pauseRoll * 3_000
                }
            }
            if settings.fatigueDrift && sourceCharacterCount > 250 { interval *= 1 + Double(typedCharacters) / Double(sourceCharacterCount) * 0.09 }
            interval *= 1 + 0.10 * exp(-Double(typedCharacters) / 11)
            let microPauseRoll = unit(), microPauseLength = unit()
            if microPauseRoll < 0.012 * realism { interval += 180 + microPauseLength * 520 }
            return TimingPair(interval: bounded(interval, 20, settings.extendedThoughtPauses ? 45_000 : 8_000),
                              priorDwell: bounded(timing.priorDwell, 20, 250))
        }

        func appendCharacter(_ character: String, speedMultiplier: Double = 1) {
            let timing = cadence(for: character)
            let dwell = bounded(profile.dwellMedian * exp(gaussian() * (0.08 + realism * 0.22)), 20, 250)
            if let last = events.indices.last, events[last].kind == .character {
                // Joint observation supplies the hold preceding this IKI.
                events[last].dwell = timing.priorDwell
            }
            let priorDwell = events.last?.dwell ?? 0
            let flight = timing.interval * speedMultiplier - priorDwell
            let kind: PlannedEventKind = character == "\n" ? .enter : character == "\t" ? .tab : .character
            events.append(PlannedEvent(kind: kind, value: character, flight: flight, dwell: dwell))
            previousCharacter = character
            typedCharacters += 1
        }

        func appendKey(_ kind: PlannedEventKind, delay: Double) {
            let dwell = bounded(profile.dwellMedian * exp(gaussian() * 0.16), 20, 180)
            events.append(PlannedEvent(kind: kind, flight: bounded(delay, 20, 8_000), dwell: dwell))
            previousCharacter = "" // Corrections are not ordinary motor digraphs.
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
                let canDelay = settings.delayedRepairs && tokenIndex + 2 < tokens.count && tokens[tokenIndex + 1].allSatisfy { $0 == " " } && unit() < 0.46
                let editCounts = evidence?.editCounts ?? [:]
                let editTotal = Double(editCounts.values.reduce(0, +))
                let editWeight = min(0.75, editTotal / (editTotal + 24))
                let selectionShare = Double(editCounts["selection"] ?? 0) / max(1, editTotal)
                let wordDeleteShare = Double(editCounts["wordDelete"] ?? 0) / max(1, editTotal)
                let selectsWholeWord = unit() < 0.36 * (1 - editWeight) + selectionShare * editWeight
                let deletesWholeWord = unit() < 0.25 * (1 - editWeight) + wordDeleteShare * editWeight && wrong.utf8.allSatisfy { (65...90).contains($0) || (97...122).contains($0) }
                func eraseWrong() {
                    if deletesWholeWord { appendKey(.wordBackspace, delay: profile.repairDelay * (0.8 + unit())) }
                    else {
                        for index in 0..<wrong.count {
                            appendKey(selectsWholeWord ? .shiftArrowLeft : .backspace,
                                      delay: index == 0 ? profile.repairDelay * (0.55 + unit()) : 36 + unit() * 34)
                        }
                    }
                }
                if canDelay {
                    let carried = tokens[tokenIndex + 1] + tokens[tokenIndex + 2]
                    carried.forEach { appendCharacter(String($0)) }
                    for move in 0..<carried.count { appendKey(.arrowLeft, delay: move == 0 ? profile.repairDelay * (1.1 + unit()) : 30 + unit() * 24) }
                    eraseWrong()
                    token.forEach { appendCharacter(String($0), speedMultiplier: 0.82) }
                    for _ in 0..<carried.count { appendKey(.arrowRight, delay: 28 + unit() * 20) }
                    tokenIndex += 3
                } else {
                    eraseWrong()
                    token.forEach { appendCharacter(String($0), speedMultiplier: 0.82) }
                    tokenIndex += 1
                }
                repairs += 1
                continue
            }

            let characters = Array(token)
            let mistakeIndex = min(characters.count - 2, max(1, Int(unit() * Double(max(1, characters.count - 2))) + 1))
            let choice = unit()
            if choice < 0.12 && settings.delayedRepairs {
                // Omit a character, notice later, insert it and return to the end.
                for index in characters.indices where index != mistakeIndex { appendCharacter(String(characters[index])) }
                let carried = characters.count - mistakeIndex - 1
                for move in 0..<carried { appendKey(.arrowLeft, delay: move == 0 ? profile.repairDelay : 45 + unit() * 25) }
                appendCharacter(String(characters[mistakeIndex]), speedMultiplier: 0.85)
                for _ in 0..<carried { appendKey(.arrowRight, delay: 40 + unit() * 20) }
            } else if choice < 0.24 {
                // Extra-character insertion is distinct from substituting a key.
                for index in characters.indices {
                    appendCharacter(String(characters[index]))
                    if index == mistakeIndex {
                        appendCharacter("e")
                        appendKey(.backspace, delay: profile.repairDelay * (0.5 + unit()))
                    }
                }
            } else if choice < 0.43 && mistakeIndex + 1 < characters.count {
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
                        let learned = (profile.confusions[intended.lowercased()] ?? []).filter { $0.count == 1 && $0.first?.isLetter == true }
                        let neighborChoices = intended.lowercased().first.flatMap { neighbors[$0] } ?? []
                        let wrong: String
                        if learned.count >= 3 && unit() < min(0.8, Double(learned.count) / Double(learned.count + 12)) { wrong = learned[min(learned.count - 1, Int(unit() * Double(learned.count)))] }
                        else if let adjacent = neighborChoices.randomElement(using: &random) { wrong = String(adjacent) }
                        else { wrong = intended }
                        appendCharacter(wrong)
                        if choice > 0.82 { appendCharacter(wrong) }
                        let observedDetection = evidence?.detectionDistances.randomElement(using: &random) ?? (profile.detectionCharacters * -log(max(0.000_001, 1 - unit())))
                        let detectionExtra = Int(max(0, min(8, observedDetection.rounded())))
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

        let timeline = KeyTimeline.normalized(events)
        events = timeline.events
        let duration = timeline.duration
        let effective = Int(((Double(sourceCharacterCount) / 5) / max(duration / 60_000, 0.001)).rounded())
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

}
