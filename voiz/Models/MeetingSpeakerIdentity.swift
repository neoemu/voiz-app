import Foundation

extension MeetingSession {
    /// Recover the roster from recorded turns, including older sessions with orphaned speech.
    /// A legacy name can resolve an ID only when it is unique within that capture source.
    mutating func reconcileSpeakers() {
        let originalSpeakers = speakers
        for index in turns.indices {
            let turn = turns[index]
            let matches = originalSpeakers.filter { $0.source == turn.source && $0.name == turn.speakerName }
            let id = turn.speakerId ?? (matches.count == 1 ? matches[0].id :
                "unidentified:\(turn.source.rawValue):\(turn.speakerName)")
            turns[index].speakerId = id
            if let speaker = speakers.first(where: { $0.id == id && $0.source == turn.source }) {
                turns[index].speakerName = speaker.name
            } else {
                speakers.append(MeetingSpeaker(id: id, source: turn.source, name: turn.speakerName))
            }
        }
    }

    mutating func renameSpeaker(id: String, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        reconcileSpeakers()
        applySpeakerNames([id: trimmed])
    }

    /// Apply one snapshot by ID, so duplicate names and name swaps cannot cascade.
    mutating func applySpeakerNames(_ namesByID: [String: String]) {
        guard !namesByID.isEmpty else { return }
        reconcileSpeakers()
        for index in speakers.indices {
            guard let name = namesByID[speakers[index].id]?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !name.isEmpty else { continue }
            speakers[index].name = name
        }
        reconcileSpeakers()
    }

    mutating func applyDiarization(segments: [DiarizedSegment]) {
        guard segments.contains(where: \.isAssigned) else {
            reconcileSpeakers()
            return
        }
        var firstSeen: [String: TimeInterval] = [:]
        for segment in segments where segment.isAssigned {
            firstSeen[segment.speakerId] = min(firstSeen[segment.speakerId] ?? segment.start, segment.start)
        }
        let clusters = firstSeen.sorted {
            $0.value == $1.value ? $0.key < $1.key : $0.value < $1.value
        }.map(\.key)
        let mic = speakers.first { $0.source == .microphone } ?? MeetingSpeaker(source: .microphone)
        let unresolved = speakers.first { $0.id == MeetingCaptureSource.systemAudio.rawValue }
            ?? MeetingSpeaker(source: .systemAudio)
        speakers = [mic] + clusters.enumerated().map { index, cluster in
            MeetingSpeaker(
                id: cluster, source: .systemAudio, name: String(localized: "Participante \(index + 1)"),
                embedding: segments.filter { $0.speakerId == cluster }.max { $0.duration < $1.duration }?.embedding
            )
        }
        for index in turns.indices {
            if turns[index].source == .microphone {
                turns[index].speakerId = mic.id
            } else {
                let cluster = DiarizationTurnAttribution.dominantCluster(
                    start: turns[index].startTime, end: turns[index].endTime, segments: segments
                )
                // A new pass must clear stale cluster IDs when it cannot identify this speech.
                turns[index].speakerId = cluster ?? unresolved.id
                if cluster == nil { turns[index].speakerName = unresolved.name }
            }
        }
        // Add the generic group only if there are actual unassigned turns.
        reconcileSpeakers()
    }
}
