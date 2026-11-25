import Foundation

nonisolated struct MeetingVoiceHint: Equatable, Sendable {
    var name: String
    var similarity: Float
    var isStrong: Bool
    var sampleCount: Int
}

nonisolated struct MeetingVoiceProfile: Equatable, Sendable {
    var name: String
    var canonicalName: String
    var centroid: [Float]
    var sampleCount: Int
    var totalWeight: TimeInterval
}

nonisolated struct MeetingVoiceMatchReport: Equatable, Sendable {
    var strongMatches: [String: MeetingVoiceHint]
    var hintsBySpeakerID: [String: [MeetingVoiceHint]]

    static let empty = MeetingVoiceMatchReport(strongMatches: [:], hintsBySpeakerID: [:])
}

nonisolated struct MeetingKnownPerson: Equatable, Sendable {
    var name: String
    var meetingCount: Int
    var hasVoiceProfile: Bool
}

nonisolated struct MeetingParticipantContext: Equatable, Sendable {
    var userDisplayName: String?
    var meetingTitle: String
    var expectedParticipants: [String]
    var knownPeopleFromHistory: [String]
    var voiceReport: MeetingVoiceMatchReport
    var notesForNaming: String?

    static let empty = MeetingParticipantContext(
        userDisplayName: nil,
        meetingTitle: "",
        expectedParticipants: [],
        knownPeopleFromHistory: [],
        voiceReport: .empty,
        notesForNaming: nil
    )
}

nonisolated struct MeetingSpeakerNameSuggestion: Equatable, Sendable {
    nonisolated enum Confidence: String, Sendable, Equatable {
        case high
        case medium
        case low
    }

    var name: String
    var confidence: Confidence
    var reason: String?

    init(name: String, confidence: Confidence, reason: String? = nil) {
        self.name = name
        self.confidence = confidence
        self.reason = reason
    }
}

nonisolated enum MeetingParticipantMemory {
    static let minimumHintSimilarity: Float = 0.74
    static let expectedBoostSimilarity: Float = 0.80
    static let minimumStrongSimilarity: Float = 0.84
    static let minimumAmbiguityMargin: Float = 0.05

    private static let exactGenericLabels: Set<String> = [
        "voce", "you",
        "outros na chamada", "others on the call",
        "outros", "others",
        "eles", "them",
        "participantes", "participants",
        "participante", "participant",
        "speaker", "falante",
        "desconhecido", "unknown"
    ]

    private static let statusHeaderKeywords: Set<String> = [
        "aceito", "seguindo", "nao respondeu", "sem resposta", "aguardando resposta",
        "recusado", "recusada", "tentativa", "talvez", "desconhecido",
        "organizador", "organizadora", "participantes", "convidados",
        "accepted", "following", "no response", "awaiting response",
        "declined", "tentative", "maybe", "unknown",
        "organizer", "attendees", "participants",
        "obrigatoria", "obrigatorio", "opcional", "required", "optional", "attendee"
    ]

    private static let roleLabels: Set<String> = [
        "obrigatoria", "obrigatorio", "opcional", "organizador", "organizadora",
        "required", "optional", "organizer", "attendee", "participante", "convidado", "convidada",
        "externo", "externa", "external", "voce", "you", "tentative", "accepted", "declined"
    ]

    private static let titleStopWords: Set<String> = [
        "com", "para", "por", "uma", "uns", "umas", "dos", "das", "nos", "nas",
        "sobre", "entre", "reuniao", "meeting", "call", "and", "the", "with", "for"
    ]

    // MARK: - String Normalization & Copy-Paste Parsing

    static func canonicalKey(_ name: String) -> String {
        name.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
    }

    static func firstNameKey(_ name: String) -> String {
        canonicalKey(name).split(separator: " ").first.map(String.init) ?? ""
    }

    static func isGenericSpeakerLabel(_ name: String) -> Bool {
        let key = canonicalKey(name)
        guard !key.isEmpty else { return true }
        if exactGenericLabels.contains(key) { return true }
        if key.range(of: #"^s\d{1,3}$"#, options: .regularExpression) != nil { return true }
        if key.range(of: #"^(participante|participant|speaker|falante)[\s_-]*\d+$"#, options: .regularExpression) != nil {
            return true
        }
        return false
    }

    static func parseExpectedParticipants(from raw: String) -> [String] {
        let normalizedNewlines = raw
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        let pieces = normalizedNewlines
            .components(separatedBy: CharacterSet(charactersIn: "\n;"))
            .compactMap(cleanCopiedParticipantLine)
        return normalizeExpectedParticipants(pieces)
    }

    static func normalizeExpectedParticipants(_ names: [String]) -> [String] {
        var seen: Set<String> = []
        var result: [String] = []
        for raw in names {
            let cleaned = raw
                .split(whereSeparator: \.isWhitespace)
                .joined(separator: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !cleaned.isEmpty, cleaned.count <= 120 else { continue }
            guard !isGenericSpeakerLabel(cleaned) else { continue }
            let key = canonicalKey(cleaned)
            guard !key.isEmpty, seen.insert(key).inserted else { continue }
            result.append(cleaned)
        }
        return result
    }

    private static func cleanCopiedParticipantLine(_ rawLine: String) -> String? {
        var line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !line.isEmpty else { return nil }

        // Remove bullets/numbering and trailing info glyph from Teams/Outlook lists.
        line = line.replacingOccurrences(of: #"^[•*·\-]+\s*"#, with: "", options: .regularExpression)
        line = line.replacingOccurrences(of: #"^\d+[\.)]\s*"#, with: "", options: .regularExpression)
        line = line.replacingOccurrences(of: #"\s*ⓘ\s*$"#, with: "", options: .regularExpression)
        line = line.replacingOccurrences(of: #"\s*<[^>]*@[^>]*>\s*$"#, with: "", options: .regularExpression)
        line = line.replacingOccurrences(of: #"\s*\[[^\]]*@[^\]]*\]\s*$"#, with: "", options: .regularExpression)

        while let range = line.range(of: #"\s*\(([^)]+)\)\s*$"#, options: .regularExpression) {
            let inside = canonicalKey(String(line[range]).trimmingCharacters(in: CharacterSet(charactersIn: "() ")))
            if roleLabels.contains(inside) {
                line.removeSubrange(range)
            } else {
                break
            }
        }

        if let dashRange = line.range(of: #"\s+[–—-]\s+([^\s–—-].*)$"#, options: .regularExpression) {
            let suffix = String(line[dashRange]).replacingOccurrences(of: #"^\s+[–—-]\s+"#, with: "", options: .regularExpression)
            if roleLabels.contains(canonicalKey(suffix)) {
                line.removeSubrange(dashRange)
            }
        }

        line = line
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard !line.isEmpty else { return nil }
        let lower = line.lowercased()
        if lower.hasPrefix("http://") || lower.hasPrefix("https://") { return nil }
        // Ignore bare email addresses.
        if line.contains("@"), !line.contains(" ") { return nil }
        // Ignore avatar initials (single character like "J").
        if line.count <= 1 { return nil }
        // Ignore status/role header lines from Teams/Outlook ("Aceito: 3", "Seguindo: 1", "Obrigatória", etc.).
        let key = canonicalKey(line)
        if isStatusOrRoleHeader(key) { return nil }
        if !line.unicodeScalars.contains(where: { CharacterSet.letters.contains($0) }) { return nil }
        guard !isGenericSpeakerLabel(line) else { return nil }
        return line
    }

    private static func isStatusOrRoleHeader(_ key: String) -> Bool {
        if statusHeaderKeywords.contains(key) { return true }
        let strippedCounts = key
            .replacingOccurrences(of: #"\s*[:(\[]\s*\d+\s*\)?\]?\s*$"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if statusHeaderKeywords.contains(strippedCounts) { return true }
        for keyword in statusHeaderKeywords where key.hasPrefix(keyword + ":") {
            return true
        }
        return false
    }

    // MARK: - Vector Helpers

    static func validEmbedding(_ embedding: [Float]?) -> [Float]? {
        guard let embedding, !embedding.isEmpty, embedding.allSatisfy(\.isFinite) else { return nil }
        return normalized(embedding)
    }

    static func normalized(_ vector: [Float]) -> [Float]? {
        guard !vector.isEmpty, vector.allSatisfy(\.isFinite) else { return nil }
        let magnitude = sqrt(vector.reduce(Float.zero) { $0 + ($1 * $1) })
        guard magnitude > 1e-6, magnitude.isFinite else { return nil }
        return vector.map { $0 / magnitude }
    }

    static func cosineSimilarity(_ lhs: [Float], _ rhs: [Float]) -> Float? {
        guard lhs.count == rhs.count,
              let normLHS = normalized(lhs),
              let normRHS = normalized(rhs) else { return nil }
        let dot = zip(normLHS, normRHS).reduce(Float.zero) { $0 + ($1.0 * $1.1) }
        return min(1, max(-1, dot))
    }

    // MARK: - MainActor History, Voice Matching & Resolution

    @MainActor
    static func buildVoiceProfiles(
        from history: [MeetingSession],
        excluding sessionID: UUID? = nil
    ) -> [MeetingVoiceProfile] {
        struct Accumulator {
            var bestName: String
            var weightedSum: [Float]
            var totalWeight: TimeInterval
            var sampleCount: Int
        }

        var accumulators: [String: Accumulator] = [:]

        for session in history where session.id != sessionID {
            var durationBySpeakerID: [String: TimeInterval] = [:]
            for turn in session.turns {
                guard let id = turn.speakerId else { continue }
                durationBySpeakerID[id, default: 0] += max(0, turn.endTime - turn.startTime)
            }

            for speaker in session.speakers where speaker.source == .systemAudio {
                guard !isGenericSpeakerLabel(speaker.name),
                      let unitEmbedding = validEmbedding(speaker.embedding) else { continue }

                let trimmedName = speaker.name
                    .split(whereSeparator: \.isWhitespace)
                    .joined(separator: " ")
                let key = canonicalKey(trimmedName)
                guard !key.isEmpty else { continue }

                let rawDuration = durationBySpeakerID[speaker.id] ?? 0
                let weight = min(120.0, max(5.0, rawDuration))
                let floatWeight = Float(weight)

                if var existing = accumulators[key] {
                    guard existing.weightedSum.count == unitEmbedding.count else { continue }
                    for idx in existing.weightedSum.indices {
                        existing.weightedSum[idx] += unitEmbedding[idx] * floatWeight
                    }
                    existing.totalWeight += weight
                    existing.sampleCount += 1
                    if trimmedName.count > existing.bestName.count {
                        existing.bestName = trimmedName
                    }
                    accumulators[key] = existing
                } else {
                    accumulators[key] = Accumulator(
                        bestName: trimmedName,
                        weightedSum: unitEmbedding.map { $0 * floatWeight },
                        totalWeight: weight,
                        sampleCount: 1
                    )
                }
            }
        }

        return accumulators.compactMap { key, acc in
            guard let centroid = normalized(acc.weightedSum) else { return nil }
            return MeetingVoiceProfile(
                name: acc.bestName,
                canonicalName: key,
                centroid: centroid,
                sampleCount: acc.sampleCount,
                totalWeight: acc.totalWeight
            )
        }.sorted {
            if $0.totalWeight != $1.totalWeight { return $0.totalWeight > $1.totalWeight }
            return $0.canonicalName < $1.canonicalName
        }
    }

    @MainActor
    static func matchSpeakers(
        _ speakers: [MeetingSpeaker],
        against profiles: [MeetingVoiceProfile],
        expectedParticipants: [String] = []
    ) -> MeetingVoiceMatchReport {
        let eligibleSpeakers = speakers.filter { speaker in
            speaker.source == .systemAudio
                && speaker.id != MeetingCaptureSource.systemAudio.rawValue
                && !speaker.id.hasPrefix("unidentified:")
                && validEmbedding(speaker.embedding) != nil
        }
        guard !eligibleSpeakers.isEmpty, !profiles.isEmpty else { return .empty }

        let similarities: [[Float?]] = eligibleSpeakers.map { speaker in
            let embedding = validEmbedding(speaker.embedding) ?? []
            return profiles.map { profile in
                cosineSimilarity(embedding, profile.centroid)
            }
        }

        let assignment = DiarizationWindowLinker.optimalAssignment(
            similarities: similarities,
            minimumSimilarity: minimumHintSimilarity
        )

        var strongMatches: [String: MeetingVoiceHint] = [:]
        var hintsBySpeakerID: [String: [MeetingVoiceHint]] = [:]

        for (speakerIndex, speaker) in eligibleSpeakers.enumerated() {
            let row = similarities[speakerIndex]
            let assignedProfileIndex = assignment[speakerIndex]

            var isAssignedStrong = false
            if let profileIndex = assignedProfileIndex,
               let sim = row[profileIndex] {
                let profile = profiles[profileIndex]
                let secondBest = row.enumerated()
                    .filter { $0.offset != profileIndex }
                    .compactMap(\.element)
                    .max()
                let hasClearMargin = secondBest == nil || (sim - secondBest!) >= minimumAmbiguityMargin
                let boostedByExpected = matchesExpectedParticipant(
                    profileName: profile.name,
                    expectedParticipants: expectedParticipants,
                    allProfiles: profiles
                )
                let passesThreshold = sim >= minimumStrongSimilarity
                    || (boostedByExpected && sim >= expectedBoostSimilarity)

                if passesThreshold && hasClearMargin {
                    isAssignedStrong = true
                    strongMatches[speaker.id] = MeetingVoiceHint(
                        name: profile.name,
                        similarity: sim,
                        isStrong: true,
                        sampleCount: profile.sampleCount
                    )
                }
            }

            let hints: [MeetingVoiceHint] = row.enumerated()
                .compactMap { profileIndex, sim -> MeetingVoiceHint? in
                    guard let sim, sim >= minimumHintSimilarity else { return nil }
                    let profile = profiles[profileIndex]
                    let isStrong = isAssignedStrong && assignedProfileIndex == profileIndex
                    return MeetingVoiceHint(
                        name: profile.name,
                        similarity: sim,
                        isStrong: isStrong,
                        sampleCount: profile.sampleCount
                    )
                }
                .sorted {
                    if $0.similarity != $1.similarity { return $0.similarity > $1.similarity }
                    return $0.name < $1.name
                }
                .prefix(2)
                .map { $0 }

            if !hints.isEmpty {
                hintsBySpeakerID[speaker.id] = hints
            }
        }

        return MeetingVoiceMatchReport(
            strongMatches: strongMatches,
            hintsBySpeakerID: hintsBySpeakerID
        )
    }

    private static func matchesExpectedParticipant(
        profileName: String,
        expectedParticipants: [String],
        allProfiles: [MeetingVoiceProfile]
    ) -> Bool {
        let normalizedExpected = normalizeExpectedParticipants(expectedParticipants)
        guard !normalizedExpected.isEmpty else { return false }

        let profileKey = canonicalKey(profileName)
        if normalizedExpected.contains(where: { canonicalKey($0) == profileKey }) {
            return true
        }

        let profileFirst = firstNameKey(profileName)
        guard !profileFirst.isEmpty else { return false }
        let expectedWithFirst = normalizedExpected.filter { firstNameKey($0) == profileFirst }
        let profilesWithFirst = allProfiles.filter { firstNameKey($0.name) == profileFirst }
        return expectedWithFirst.count == 1 && profilesWithFirst.count <= 1
    }

    @MainActor
    static func knownPeople(
        from sessions: [MeetingSession],
        folders: [MeetingFolder],
        excluding sessionID: UUID? = nil,
        preferredFolderID: UUID? = nil,
        referenceTitle: String? = nil,
        limit: Int? = 25
    ) -> [MeetingKnownPerson] {
        struct Entry {
            var bestName: String
            var sessionIDs: Set<UUID> = []
            var score: Double = 0
            var hasVoiceProfile: Bool = false
        }

        let profiles = buildVoiceProfiles(from: sessions, excluding: sessionID)
        let voiceProfileKeys = Set(profiles.map(\.canonicalName))
        let referenceTokens = titleTokens(referenceTitle ?? "")

        var entries: [String: Entry] = [:]

        func record(_ rawName: String, sessionID: UUID?, weight: Double) {
            let cleaned = rawName
                .split(whereSeparator: \.isWhitespace)
                .joined(separator: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !cleaned.isEmpty, cleaned.count <= 120, !isGenericSpeakerLabel(cleaned) else { return }
            let key = canonicalKey(cleaned)
            guard !key.isEmpty else { return }

            var entry = entries[key] ?? Entry(bestName: cleaned)
            if let sessionID { entry.sessionIDs.insert(sessionID) }
            entry.score += weight
            if voiceProfileKeys.contains(key) { entry.hasVoiceProfile = true }
            if preferName(cleaned, over: entry.bestName) {
                entry.bestName = cleaned
            }
            entries[key] = entry
        }

        for folder in folders {
            let bonus: Double = (preferredFolderID != nil && folder.id == preferredFolderID) ? 12 : 1
            for name in normalizeExpectedParticipants(folder.expectedParticipants ?? []) {
                record(name, sessionID: nil, weight: bonus)
            }
        }

        let sortedSessions = sessions
            .filter { $0.id != sessionID }
            .sorted { $0.startedAt > $1.startedAt }

        for (index, session) in sortedSessions.enumerated() {
            let sameFolderBonus: Double = (preferredFolderID != nil && session.folderId == preferredFolderID) ? 10 : 0
            let sharedTokens = referenceTokens.isEmpty
                ? 0
                : titleTokens(session.title).intersection(referenceTokens).count
            let titleBonus = Double(sharedTokens) * 6.0
            let recencyBonus = max(0.0, 2.0 - Double(index) * 0.05)

            for speaker in session.speakers where speaker.source == .systemAudio {
                record(speaker.name, sessionID: session.id, weight: 3.0 + sameFolderBonus + titleBonus + recencyBonus)
            }
            for expected in normalizeExpectedParticipants(session.expectedParticipants ?? []) {
                record(expected, sessionID: session.id, weight: 2.0 + sameFolderBonus + titleBonus + recencyBonus)
            }
            for item in session.summary?.allActionItems ?? [] {
                if let assignee = item.assignee {
                    record(assignee, sessionID: session.id, weight: 1.0 + sameFolderBonus + titleBonus)
                }
            }
        }

        let sorted = entries.values
            .map {
                MeetingKnownPerson(
                    name: $0.bestName,
                    meetingCount: $0.sessionIDs.count,
                    hasVoiceProfile: $0.hasVoiceProfile
                )
            }
            .sorted { lhs, rhs in
                let lhsScore = entries[canonicalKey(lhs.name)]?.score ?? 0
                let rhsScore = entries[canonicalKey(rhs.name)]?.score ?? 0
                if lhsScore != rhsScore { return lhsScore > rhsScore }
                if lhs.hasVoiceProfile != rhs.hasVoiceProfile { return lhs.hasVoiceProfile && !rhs.hasVoiceProfile }
                if lhs.meetingCount != rhs.meetingCount { return lhs.meetingCount > rhs.meetingCount }
                return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
            }
        if let limit {
            return Array(sorted.prefix(max(0, limit)))
        }
        return sorted
    }

    private static func preferName(_ candidate: String, over current: String) -> Bool {
        let candidateWords = candidate.split(whereSeparator: \.isWhitespace).count
        let currentWords = current.split(whereSeparator: \.isWhitespace).count
        if candidateWords != currentWords { return candidateWords > currentWords }
        let candidateDiacritics = candidate.unicodeScalars.filter { $0.value > 127 }.count
        let currentDiacritics = current.unicodeScalars.filter { $0.value > 127 }.count
        if candidateDiacritics != currentDiacritics { return candidateDiacritics > currentDiacritics }
        return false
    }

    private static func titleTokens(_ title: String) -> Set<String> {
        let key = canonicalKey(title)
        return Set(
            key.components(separatedBy: CharacterSet.alphanumerics.inverted)
                .filter { $0.count >= 3 && !titleStopWords.contains($0) }
        )
    }

    @MainActor
    static func buildContext(
        for session: MeetingSession,
        allSessions: [MeetingSession],
        folders: [MeetingFolder],
        userDisplayName: String?
    ) -> MeetingParticipantContext {
        let cleanUser = normalizedOptionalUser(userDisplayName)
        let userKey = cleanUser.map(canonicalKey)

        let folder = session.folderId.flatMap { id in folders.first { $0.id == id } }
        let mergedExpected = normalizeExpectedParticipants(
            (session.expectedParticipants ?? []) + (folder?.expectedParticipants ?? [])
        ).filter { name in
            guard let userKey else { return true }
            return canonicalKey(name) != userKey
        }
        let expectedKeys = Set(mergedExpected.map(canonicalKey))

        let knownPeople = knownPeople(
            from: allSessions,
            folders: folders,
            excluding: session.id,
            preferredFolderID: session.folderId,
            referenceTitle: session.title,
            limit: 35
        )
        .map(\.name)
        .filter { name in
            let key = canonicalKey(name)
            if let userKey, key == userKey { return false }
            return !expectedKeys.contains(key)
        }
        .prefix(25)
        .map { $0 }

        let profiles = buildVoiceProfiles(from: allSessions, excluding: session.id)
        let filteredProfiles = profiles.filter { profile in
            guard let userKey else { return true }
            return profile.canonicalName != userKey
        }
        let voiceReport = matchSpeakers(
            session.speakers,
            against: filteredProfiles,
            expectedParticipants: mergedExpected
        )

        let notes = session.usesNotesInSummary
            ? session.notes.trimmingCharacters(in: .whitespacesAndNewlines)
            : ""

        return MeetingParticipantContext(
            userDisplayName: cleanUser,
            meetingTitle: session.title,
            expectedParticipants: mergedExpected,
            knownPeopleFromHistory: knownPeople,
            voiceReport: voiceReport,
            notesForNaming: notes.isEmpty ? nil : notes
        )
    }

    @MainActor
    static func suggestedRenameNames(
        for speaker: MeetingSpeaker,
        in session: MeetingSession,
        allSessions: [MeetingSession],
        folders: [MeetingFolder],
        userDisplayName: String?
    ) -> [String] {
        let context = buildContext(
            for: session,
            allSessions: allSessions,
            folders: folders,
            userDisplayName: userDisplayName
        )

        let usedByOthers = Set(
            session.speakers
                .filter { $0.id != speaker.id && !isGenericSpeakerLabel($0.name) }
                .map { canonicalKey($0.name) }
        )
        let currentKey = isGenericSpeakerLabel(speaker.name) ? nil : canonicalKey(speaker.name)
        let voiceCandidates = (context.voiceReport.hintsBySpeakerID[speaker.id] ?? []).map(\.name)

        var ordered: [String] = []
        var seen: Set<String> = []
        let allCandidates = voiceCandidates + context.expectedParticipants + context.knownPeopleFromHistory
        for candidate in allCandidates {
            let key = canonicalKey(candidate)
            guard !key.isEmpty,
                  key != currentKey,
                  !usedByOthers.contains(key),
                  seen.insert(key).inserted else { continue }
            ordered.append(candidate)
        }
        return ordered
    }

    @MainActor
    static func resolveFinalNames(
        llmSuggestions: [String: MeetingSpeakerNameSuggestion],
        voiceReport: MeetingVoiceMatchReport,
        speakers: [MeetingSpeaker],
        userDisplayName: String?
    ) -> [String: String] {
        let userKey = normalizedOptionalUser(userDisplayName).map(canonicalKey)
        var resolved: [String: String] = [:]

        for speaker in speakers {
            guard speaker.source == .systemAudio,
                  speaker.id != MeetingCaptureSource.systemAudio.rawValue,
                  !speaker.id.hasPrefix("unidentified:") else { continue }

            let strongVoice = voiceReport.strongMatches[speaker.id].flatMap { hint -> MeetingVoiceHint? in
                guard !isGenericSpeakerLabel(hint.name) else { return nil }
                if let userKey, canonicalKey(hint.name) == userKey { return nil }
                return hint
            }

            let validLLM = llmSuggestions[speaker.id].flatMap { suggestion -> MeetingSpeakerNameSuggestion? in
                let trimmed = suggestion.name
                    .split(whereSeparator: \.isWhitespace)
                    .joined(separator: " ")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty,
                      !isGenericSpeakerLabel(trimmed),
                      suggestion.confidence != .low else { return nil }
                if let userKey, canonicalKey(trimmed) == userKey { return nil }
                return MeetingSpeakerNameSuggestion(
                    name: trimmed,
                    confidence: suggestion.confidence,
                    reason: suggestion.reason
                )
            }

            if let llm = validLLM {
                switch llm.confidence {
                case .high:
                    if let strongVoice,
                       isSingleWord(llm.name),
                       firstNameKey(llm.name) == firstNameKey(strongVoice.name) {
                        resolved[speaker.id] = strongVoice.name
                    } else {
                        resolved[speaker.id] = llm.name
                    }
                case .medium:
                    if let strongVoice,
                       (canonicalKey(llm.name) == canonicalKey(strongVoice.name)
                        || (isSingleWord(llm.name) && firstNameKey(llm.name) == firstNameKey(strongVoice.name))) {
                        resolved[speaker.id] = strongVoice.name
                    } else {
                        resolved[speaker.id] = llm.name
                    }
                case .low:
                    if let strongVoice {
                        resolved[speaker.id] = strongVoice.name
                    }
                }
            } else if let strongVoice {
                resolved[speaker.id] = strongVoice.name
            }
        }

        return resolved
    }

    private static func isSingleWord(_ name: String) -> Bool {
        name.split(whereSeparator: \.isWhitespace).count == 1
    }

    private static func normalizedOptionalUser(_ raw: String?) -> String? {
        guard let trimmed = raw?.split(whereSeparator: \.isWhitespace).joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !trimmed.isEmpty else { return nil }
        return trimmed
    }
}
