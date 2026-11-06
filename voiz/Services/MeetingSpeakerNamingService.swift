import Foundation

/// Camada 2 da identificação: lê o transcript já diarizado e infere os **nomes reais**
/// dos falantes a partir do que é dito na conversa (auto-apresentação "eu sou o João",
/// "aqui é o Rodrigo"). Reusa a mesma chamada de LLM do resumo — nenhuma voz sai do Mac,
/// só o texto que o usuário já manda pro provider que ele controla.
///
/// É **sugestão**: só devolve nomes revelados com clareza; o resto fica como "Participante N"
/// e o usuário corrige na UI.
final class MeetingSpeakerNamingService {
    private let completionService: AICompletionService

    init(settings: AppSettings) {
        self.completionService = AICompletionService(
            provider: settings.translationProvider,
            apiKey: settings.currentAPIKey,
            model: settings.currentModelId,
            baseURL: settings.currentBaseURL,
            reasoningEffort: settings.currentReasoningEffort
        )
    }

    func updateSettings(_ settings: AppSettings) {
        completionService.apply(settings)
    }

    /// Mapeia ID estável do falante → nome real, quando revelado.
    /// Rótulos sem evidência clara não aparecem no resultado.
    func suggestNames(for session: MeetingSession) async throws -> [String: String] {
        var session = session
        session.reconcileSpeakers()
        let transcript = session.turns.map {
            "[\($0.speakerId ?? $0.source.rawValue)] \($0.speakerName): \($0.text)"
        }.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !transcript.isEmpty else { return [:] }

        // Unassigned speech may contain several people; do not invent one identity for the group.
        let identified = session.speakers.filter {
            $0.source == .microphone || ($0.id != MeetingCaptureSource.systemAudio.rawValue
                && !$0.id.hasPrefix("unidentified:"))
        }
        let labels = identified.map(\.id)
        let prompt = prompt(labels: identified.map { "[\($0.id)] \($0.name)" }, transcript: transcript)
        let response = try await completionService.completeAccumulating(prompt: prompt, temperature: 0.1)
        return parseNames(from: response, knownLabels: Set(labels))
    }

    private func prompt(labels: [String], transcript: String) -> String {
        let labelList = labels.map { "- \($0)" }.joined(separator: "\n")
        return """
        Você identifica os nomes reais dos falantes a partir do que é dito numa reunião.

        Falantes (IDs estáveis entre colchetes e nomes atuais):
        \(labelList)

        Transcript com falantes:
        \(transcript)

        Regras:
        - Atribua um nome real a um rótulo APENAS se for revelado com clareza, principalmente por
          auto-apresentação ("eu sou o X", "aqui é o X", "quem fala é o X") ou se a pessoa for
          chamada por alguém e claramente responder/assumir aquele nome.
        - Chamar outra pessoa ("oi Marcos", "obrigado Marcos") NÃO nomeia quem está falando — isso
          só indica que existe um Marcos entre os outros falantes.
        - Na dúvida, não atribua. É melhor deixar sem nome do que errar.

        Pessoas diferentes podem ter o mesmo nome; preserve cada ID separadamente.
        Retorne APENAS JSON válido, sem markdown, mapeando ID → nome real. Inclua somente os
        IDs listados cujo nome você descobriu com confiança. Exemplo:
        {"microphone": "Rodrigo", "S1": "João"}
        Se não descobrir nenhum, retorne {}.
        """
    }

    private func parseNames(from response: String, knownLabels: Set<String>) -> [String: String] {
        let tick = String(UnicodeScalar(96))
        let fence = String(repeating: tick, count: 3)
        let cleaned = response
            .replacingOccurrences(of: fence + "json", with: "")
            .replacingOccurrences(of: fence, with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard let data = cleaned.data(using: .utf8),
              let decoded = try? JSONDecoder().decode([String: String].self, from: data) else {
            return [:]
        }

        // Só aceita rótulos que existem na sessão e nomes não vazios.
        var result: [String: String] = [:]
        for (label, name) in decoded {
            let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
            if knownLabels.contains(label), !trimmed.isEmpty {
                result[label] = trimmed
            }
        }
        return result
    }
}
