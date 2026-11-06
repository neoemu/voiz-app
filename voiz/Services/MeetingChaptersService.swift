import Foundation

/// Gera **capítulos/tópicos** da reunião a partir do transcript com timestamps. O LLM devolve
/// uma lista de `{time, title}`; convertemos `time` (mm:ss) em segundos e amarramos ao player.
/// Roda no endpoint que o usuário controla (posicionamento BYO).
final class MeetingChaptersService {
    private let completionService: AICompletionService

    /// Idioma pedido ao modelo — vem do ajuste "Idioma das notas" (Configurações → Reuniões).
    private var languageInstruction: String = ""

    init(settings: AppSettings) {
        self.languageInstruction = settings.notesLanguageInstruction
        self.completionService = AICompletionService(
            provider: settings.translationProvider,
            apiKey: settings.currentAPIKey,
            model: settings.currentModelId,
            baseURL: settings.currentBaseURL,
            reasoningEffort: settings.currentReasoningEffort
        )
    }

    func updateSettings(_ settings: AppSettings) {
        languageInstruction = settings.notesLanguageInstruction
        completionService.apply(settings)
    }

    func chapters(for session: MeetingSession) async throws -> [MeetingChapter] {
        let lines = session.turns.compactMap { turn -> String? in
            let text = turn.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }
            return "[\(timeLabel(turn.startTime))] \(turn.speakerName): \(text)"
        }
        guard !lines.isEmpty else { return [] }

        let maxDuration = session.duration

        let prompt = """
        Você recebe o transcript de uma reunião com timestamps no formato [mm:ss]. Divida a conversa \
        em CAPÍTULOS (tópicos) na ordem em que aparecem. Cada capítulo tem um título curto (3-6 \
        palavras) e o timestamp em que aquele tópico começa.
        \(languageInstruction)

        Regras:
        - Entre 3 e 8 capítulos. Reuniões curtas podem ter menos.
        - O "time" deve ser EXATAMENTE um dos timestamps que aparecem no transcript (formato mm:ss).
        - O primeiro capítulo começa perto de 00:00.
        - Baseie-se SÓ no que está no transcript; não invente tópicos.
        - Responda APENAS um array JSON, sem texto fora dele:
          [{"time":"mm:ss","title":"..."}]

        TRANSCRIPT:
        \(lines.joined(separator: "\n"))
        """

        let raw = try await completionService.completeAccumulating(prompt: prompt, temperature: 0.3)
        return parse(raw, maxDuration: maxDuration)
    }

    // MARK: - Parsing

    private struct RawChapter: Decodable {
        let time: String
        let title: String
    }

    private func parse(_ raw: String, maxDuration: TimeInterval) -> [MeetingChapter] {
        let cleaned = stripCodeFence(raw)
        guard let start = cleaned.firstIndex(of: "["),
              let end = cleaned.lastIndex(of: "]"),
              let data = String(cleaned[start...end]).data(using: .utf8),
              let decoded = try? JSONDecoder().decode([RawChapter].self, from: data)
        else { return [] }

        let chapters: [MeetingChapter] = decoded.compactMap { item in
            let title = item.title.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty, let seconds = parseTime(item.time) else { return nil }
            let clamped = maxDuration > 0 ? min(seconds, maxDuration) : seconds
            return MeetingChapter(title: title, startTime: clamped)
        }
        // Ordena por tempo e remove duplicatas no mesmo instante.
        var seen = Set<Int>()
        return chapters
            .sorted { $0.startTime < $1.startTime }
            .filter { seen.insert(Int($0.startTime)).inserted }
    }

    private func parseTime(_ raw: String) -> TimeInterval? {
        let parts = raw.trimmingCharacters(in: .whitespaces).split(separator: ":").map { Int($0) }
        guard parts.allSatisfy({ $0 != nil }) else { return nil }
        let nums = parts.compactMap { $0 }
        switch nums.count {
        case 2: return TimeInterval(nums[0] * 60 + nums[1])
        case 3: return TimeInterval(nums[0] * 3600 + nums[1] * 60 + nums[2])
        default: return nil
        }
    }

    private func stripCodeFence(_ text: String) -> String {
        var s = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("```") {
            s = s.replacingOccurrences(of: "```json", with: "")
            s = s.replacingOccurrences(of: "```", with: "")
        }
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func timeLabel(_ time: TimeInterval) -> String {
        let total = max(0, Int(time))
        return String(format: "%02d:%02d", total / 60, total % 60)
    }
}
