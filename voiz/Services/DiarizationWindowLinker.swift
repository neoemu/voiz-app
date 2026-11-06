import Foundation

/// Segmento "quem falou quando" já mapeado para tipos do Voiz. Tempos em segundos a partir do
/// início do arquivo de áudio; o embedding permanece junto do segmento para a costura global.
struct DiarizedSegment: Equatable, Sendable {
    /// Fala detectada cuja identidade o linker NÃO conseguiu resolver (faixa de
    /// incerteza 0,60…0,78, ou curta demais para criar um global). Antes essas
    /// observações eram omitidas: o texto do ASR ficava, mas a evidência de
    /// falante sumia, e o `applyDiarization` empurrava o turn para o segmento
    /// mais próximo — não-atribuído virava atribuição ERRADA. Emitir o
    /// sentinela preserva "alguém falou aqui, não sei quem", que é uma
    /// informação diferente de "ninguém falou aqui".
    static let unassignedSpeakerId = "__unassigned__"

    let speakerId: String
    let start: TimeInterval
    let end: TimeInterval
    let embedding: [Float]

    var duration: TimeInterval { max(0, end - start) }
    var isAssigned: Bool { speakerId != Self.unassignedSpeakerId }
}

/// Agregados de uma diarização — o que o veredito das proxies precisa e o log
/// antigo não dava. Nada aqui deriva de texto de fala.
struct DiarizationLinkStats: Equatable, Sendable {
    /// União temporal de TODA fala que os diarizadores devolveram, antes de
    /// qualquer recorte ou descarte. É o denominador honesto: usar a soma do
    /// que sobrou faz a fração minoritária subir ao descartar fala dominante e
    /// cair ao descartar fala minoritária.
    var rawDuration: TimeInterval = 0
    /// União temporal do que saiu com identidade global.
    var assignedDuration: TimeInterval = 0
    /// União temporal do que saiu com o sentinela.
    var unassignedDuration: TimeInterval = 0
    /// Fala que não sobreviveu à materialização (recorte de ownership).
    var droppedDuration: TimeInterval = 0
    var durationByCluster: [String: TimeInterval] = [:]
    /// Em quantas janelas distintas cada global apareceu. Um global que só
    /// aparece numa janela é candidato a fragmento.
    var windowCountByCluster: [String: Int] = [:]
    /// Similaridade com o vizinho mais próximo no instante em que cada global
    /// NASCEU (< 0,60 por construção; -1 quando não havia nenhum outro).
    var birthSimilarityByCluster: [String: Float] = [:]
    /// Fusões da reconciliação final global-global: removido → mantido.
    var reconciledClusters: [String: String] = [:]
    /// Globais rebaixados pelo filtro de apresentação (curtos demais para virar
    /// participante): id → duração agregada. A fala deles continua no
    /// transcript, como não-identificada.
    var demotedClusters: [String: TimeInterval] = [:]
    /// Globais que nasceram por cima de uma semente fraca na faixa de incerteza:
    /// novo → sementes superadas (ver `holdsUncertaintyBand`).
    var supersededSeeds: [String: [String]] = [:]
    /// Fala sem dono religada no fim ao centroide FINAL de um participante
    /// apresentado: id → duração religada (ver `relinkUnassigned`).
    var relinkedClusters: [String: TimeInterval] = [:]

    var unassignedRate: Double {
        rawDuration > 0 ? unassignedDuration / rawDuration : 0
    }

    /// Fração minoritária com denominador RAW (não a soma do que sobrou).
    var minorityRateOverRaw: Double {
        guard rawDuration > 0 else { return 0 }
        let dominant = durationByCluster.values.max() ?? 0
        let assignedSum = durationByCluster.values.reduce(0, +)
        return max(0, assignedSum - dominant) / rawDuration
    }

    /// Uma linha, sem texto de fala, para o log do serviço.
    var logSummary: String {
        func seconds(_ value: TimeInterval) -> String { String(format: "%.2f", value) }
        let clusters = durationByCluster.sorted { $0.value > $1.value }.map { id, duration in
            let windows = windowCountByCluster[id] ?? 0
            let birth = birthSimilarityByCluster[id].map { String(format: "%.3f", $0) } ?? "n/a"
            return "\(id):\(seconds(duration))s/w\(windows)/nasc\(birth)"
        }
        return [
            "raw=\(seconds(rawDuration))s",
            "atribuida=\(seconds(assignedDuration))s",
            "nao-atribuida=\(seconds(unassignedDuration))s",
            "descartada=\(seconds(droppedDuration))s",
            "taxaNaoAtribuida=\(String(format: "%.4f", unassignedRate))",
            "minoritariaRaw=\(String(format: "%.4f", minorityRateOverRaw))",
            "clusters=[\(clusters.joined(separator: " "))]",
            "reconciliados=\(reconciledClusters.count)",
            "rebaixados=\(demotedClusters.count)",
            "sementesSuperadas=\(supersededSeeds.count)",
            "religada=\(seconds(relinkedClusters.values.reduce(0, +)))s"
        ].joined(separator: " ")
    }
}

/// Segmentos + agregados.
struct DiarizationLinkResult: Sendable {
    let segments: [DiarizedSegment]
    let stats: DiarizationLinkStats
}

/// A time range sent to one independent diarizer invocation.
struct DiarizationWindow: Equatable, Sendable {
    let index: Int
    let start: TimeInterval
    let end: TimeInterval

    var duration: TimeInterval { max(0, end - start) }
}

/// Pure window planning kept separate from the FluidAudio adapter so the boundary and overlap
/// rules can be tested without downloading models or opening an audio file.
enum DiarizationWindowPlanner {
    static let defaultWindowDuration: TimeInterval = 180
    static let defaultOverlap: TimeInterval = 60

    static func makeWindows(
        duration: TimeInterval,
        windowDuration: TimeInterval = defaultWindowDuration,
        overlap: TimeInterval = defaultOverlap
    ) -> [DiarizationWindow] {
        let duration = max(0, duration)
        guard duration > 0 else { return [] }

        let windowDuration = max(0.1, windowDuration)
        let overlap = min(max(0, overlap), windowDuration * 0.9)
        let hop = max(0.1, windowDuration - overlap)

        var windows: [DiarizationWindow] = []
        var start = 0.0
        var index = 0
        while start < duration {
            let end = min(duration, start + windowDuration)
            windows.append(DiarizationWindow(index: index, start: start, end: end))
            if end >= duration { break }
            start += hop
            index += 1
        }
        return windows
    }
}

/// Output from one independent window. FluidAudio timestamps are relative to that window.
struct DiarizationWindowResult: Sendable {
    let window: DiarizationWindow
    let segments: [DiarizedSegment]
}

/// Links window-local speaker slots into one global identity space.
///
/// The linker deliberately knows nothing about the audio engine. That makes the important
/// failure mode testable with artificial embeddings and keeps the production adapter small.
struct DiarizationWindowLinker {
    /// Cosine similarity (not distance) required for an identity match across windows.
    /// FluidAudio's online macOS default accepts cosine distance up to 0.65; global linking is
    /// stricter (similarity >= 0.78, distance <= 0.22) because it must not turn two independent
    /// local clusters into one long-lived identity. The anti-fragmentation gate below handles
    /// borderline 1:1 assignments by preferring an existing identity over a new cluster.
    static let clusterMatchSimilarity: Float = 0.78

    /// A higher bar used when two local slots in the same/overlapping window look like duplicate
    /// fragments. Similarity >= 0.88 (distance <= 0.12) is reserved for this many-to-one path;
    /// the sensitivity tests pin the behavior at 0.879/0.880.
    static let duplicateFragmentSimilarity: Float = 0.88

    /// A new identity needs enough aggregate speech to be more than a diarizer blip. This is a
    /// creation gate; short/ambiguous observations remain unassigned rather than creating ghosts.
    static let minimumNewClusterDuration: TimeInterval = 2
    /// New identities need a clear separation from every existing centroid. The 0.18 gap below
    /// the 0.78 match threshold leaves a deliberate uncertainty band (0.60...0.78): it is not
    /// safe enough to link and not distinct enough to create, so it remains unassigned. A weak
    /// seed does not hold this band against a long observation (`holdsUncertaintyBand`), and
    /// unassigned speech is tested again against the final centroids (`relinkUnassigned`).
    static let newClusterMaximumSimilarity: Float = 0.60
    static let mergeGap: TimeInterval = 0.10

    /// Filtro de APRESENTAÇÃO (decisão de produto, 2026-08-19). Um global com
    /// menos que isto de fala agregada não vira "Participante N" no card nem no
    /// export: em todas as cinco proxies apareceram de 1 a 3 desses, com menos
    /// de 10 s e 1 a 4 janelas, nascidos logo abaixo do gate de 0,60.
    ///
    /// O rebaixamento é na fronteira de materialização, NÃO nos limiares de
    /// similaridade: mexer no gate mudaria quem casa com quem, e o problema não
    /// é o casamento — é o que se mostra ao humano. A fala continua no
    /// transcript, com o mesmo tratamento do sentinela (alguém falou aqui, sem
    /// identidade confiável), então nada desaparece.
    static let minimumPresentedClusterDuration: TimeInterval = 10

    /// Links results in time order. Set `globalLinkingEnabled` to false only in the regression
    /// test that reintroduces the old defect: window-local IDs are then returned unchanged.
    static func link(
        _ results: [DiarizationWindowResult],
        globalLinkingEnabled: Bool = true
    ) -> [DiarizedSegment] {
        linkDetailed(results, globalLinkingEnabled: globalLinkingEnabled).segments
    }

    /// A mesma costura, com os agregados que o veredito das proxies exige.
    static func linkDetailed(
        _ results: [DiarizationWindowResult],
        globalLinkingEnabled: Bool = true
    ) -> DiarizationLinkResult {
        let ordered = results.sorted { $0.window.index < $1.window.index }
        guard !ordered.isEmpty else {
            return DiarizationLinkResult(segments: [], stats: DiarizationLinkStats())
        }

        var assignments: [Int: [String: String]] = [:]
        var observationsByWindow: [Int: [LocalObservation]] = [:]
        var globalClusters: [GlobalCluster] = []
        var birthSimilarity: [String: Float] = [:]
        var supersededSeeds: [String: [String]] = [:]
        // Quem apareceu JUNTO com quem, em alguma janela. A atribuição é 1:1
        // por janela, então dois globais distintos na mesma janela vieram de
        // dois slots LOCAIS distintos — o diarizador já provou que são duas
        // pessoas ali. Nenhuma reconciliação posterior pode desfazer isso.
        var coOccurrence: [String: Set<String>] = [:]

        for result in ordered {
            let observations = observations(from: result.segments, windowStart: result.window.start)
            guard !observations.isEmpty else { continue }

            if !globalLinkingEnabled {
                assignments[result.window.index] = Dictionary(
                    uniqueKeysWithValues: observations.map { ($0.localID, $0.localID) }
                )
                continue
            }

            let map = assign(
                observations,
                to: &globalClusters,
                birthSimilarity: &birthSimilarity,
                supersededSeeds: &supersededSeeds
            )
            assignments[result.window.index] = map
            observationsByWindow[result.window.index] = observations
            let present = Set(map.values)
            for id in present {
                coOccurrence[id, default: []].formUnion(present.subtracting([id]))
            }
        }

        var stats = DiarizationLinkStats()
        if globalLinkingEnabled {
            // Reconciliação FINAL global-global: um global que nasceu cedo,
            // quando ainda havia pouca evidência, nunca é reavaliado contra os
            // que nasceram depois. Sem esta passagem, dois fragmentos da mesma
            // voz sobrevivem a reunião inteira como participantes distintos.
            stats.reconciledClusters = reconcile(&globalClusters, coOccurrence: coOccurrence)
            if !stats.reconciledClusters.isEmpty {
                for (windowIndex, map) in assignments {
                    assignments[windowIndex] = map.mapValues { stats.reconciledClusters[$0] ?? $0 }
                }
            }
        }

        var materialized = materialize(
            ordered,
            assignments: assignments,
            globalLinkingEnabled: globalLinkingEnabled,
            globalCentroids: Dictionary(
                uniqueKeysWithValues: globalClusters.compactMap { cluster in
                    guard let centroid = cluster.centroid else { return nil }
                    return (cluster.id, centroid)
                }
            )
        )

        if globalLinkingEnabled {
            stats.demotedClusters = demoteShortClusters(&materialized)
            // Depois do rebaixamento: só quem segue apresentado recebe fala.
            stats.relinkedClusters = relinkUnassigned(
                &materialized,
                observationsByWindow: observationsByWindow,
                assignments: assignments,
                clusters: globalClusters
            )
        }

        let segments = mergeAdjacent(materialized.map(\.segment))
        stats.birthSimilarityByCluster = birthSimilarity.filter { id, _ in
            stats.reconciledClusters[id] == nil && stats.demotedClusters[id] == nil
        }
        stats.supersededSeeds = supersededSeeds.filter { id, _ in
            stats.reconciledClusters[id] == nil && stats.demotedClusters[id] == nil
        }
        fill(&stats, ordered: ordered, materialized: materialized, segments: segments)
        return DiarizationLinkResult(segments: segments, stats: stats)
    }

    /// Filtro de apresentação: global curto demais volta a ser fala sem
    /// identidade. Roda ANTES do merge, para os trechos rebaixados poderem se
    /// costurar com os sentinelas vizinhos.
    private static func demoteShortClusters(
        _ materialized: inout [MaterializedSegment],
        minimumDuration: TimeInterval = minimumPresentedClusterDuration
    ) -> [String: TimeInterval] {
        var spansByCluster: [String: [Range<TimeInterval>]] = [:]
        for entry in materialized where entry.segment.isAssigned {
            spansByCluster[entry.segment.speakerId, default: []]
                .append(entry.segment.start..<entry.segment.end)
        }
        let demoted = spansByCluster
            .mapValues { unionDuration($0) }
            .filter { $0.value < minimumDuration }
        guard !demoted.isEmpty else { return [:] }

        for index in materialized.indices where demoted[materialized[index].segment.speakerId] != nil {
            let segment = materialized[index].segment
            materialized[index].segment = DiarizedSegment(
                speakerId: DiarizedSegment.unassignedSpeakerId,
                start: segment.start,
                end: segment.end,
                embedding: segment.embedding
            )
        }
        return demoted
    }

    // MARK: - Aggregates

    private static func fill(
        _ stats: inout DiarizationLinkStats,
        ordered: [DiarizationWindowResult],
        materialized: [MaterializedSegment],
        segments: [DiarizedSegment]
    ) {
        let rawSpans = ordered.flatMap { result in
            result.segments.compactMap { segment -> Range<TimeInterval>? in
                let start = result.window.start + segment.start
                let end = result.window.start + segment.end
                guard end > start else { return nil }
                return start..<end
            }
        }
        stats.rawDuration = unionDuration(rawSpans)

        let assigned = segments.filter(\.isAssigned)
        let unassigned = segments.filter { !$0.isAssigned }
        stats.assignedDuration = unionDuration(assigned.map { $0.start..<$0.end })
        stats.unassignedDuration = unionDuration(unassigned.map { $0.start..<$0.end })
        stats.droppedDuration = max(
            0,
            stats.rawDuration - unionDuration(segments.map { $0.start..<$0.end })
        )

        for segment in assigned {
            stats.durationByCluster[segment.speakerId, default: 0] += segment.duration
        }

        // Janela DETECTORA, pela proveniência do segmento — não por interseção
        // temporal com os limites. Com 60 s de sobreposição, um fragmento de
        // borda cruza a janela vizinha sem ela nunca o ter detectado, e virava
        // um `w2` falso: exatamente o sinal que separa fragmento de voz real.
        // A contagem é feita ANTES do merge, que costura segmentos de janelas
        // diferentes num só.
        var windowsByCluster: [String: Set<Int>] = [:]
        for entry in materialized where entry.segment.isAssigned {
            windowsByCluster[entry.segment.speakerId, default: []].insert(entry.windowIndex)
        }
        stats.windowCountByCluster = windowsByCluster.mapValues(\.count)
        stats.birthSimilarityByCluster = stats.birthSimilarityByCluster.filter {
            stats.durationByCluster[$0.key] != nil
        }
    }

    /// Duração da UNIÃO dos intervalos — sobreposição entre janelas não pode
    /// contar duas vezes num denominador.
    static func unionDuration(_ ranges: [Range<TimeInterval>]) -> TimeInterval {
        let sorted = ranges.filter { $0.upperBound > $0.lowerBound }
            .sorted { $0.lowerBound < $1.lowerBound }
        guard var current = sorted.first else { return 0 }
        var total: TimeInterval = 0
        for range in sorted.dropFirst() {
            if range.lowerBound > current.upperBound {
                total += current.upperBound - current.lowerBound
                current = range
            } else {
                current = current.lowerBound..<max(current.upperBound, range.upperBound)
            }
        }
        total += current.upperBound - current.lowerBound
        return total
    }

    // MARK: - Local observations

    private struct LocalObservation {
        let localID: String
        let duration: TimeInterval
        let firstSeen: TimeInterval
        let embedding: [Float]?
        /// Trechos no tempo absoluto do arquivo.
        let spans: [Range<TimeInterval>]
    }

    private struct GlobalCluster {
        let id: String
        /// Trechos absolutos de todas as observações atribuídas. Com 60 s de
        /// sobreposição, a mesma fala chega por duas janelas; somar as
        /// observações contaria essa fala duas vezes.
        var spans: [Range<TimeInterval>]
        var embeddingWeight: TimeInterval
        var centroid: [Float]?
        let firstSeen: TimeInterval

        /// Fala única do global: a união dos trechos.
        var speechDuration: TimeInterval { DiarizationWindowLinker.unionDuration(spans) }
    }

    private static func observations(
        from segments: [DiarizedSegment],
        windowStart: TimeInterval
    ) -> [LocalObservation] {
        let grouped = Dictionary(grouping: segments, by: \.speakerId)
        return grouped.map { localID, segments in
            let duration = segments.reduce(0) { $0 + $1.duration }
            let embedding = representativeEmbedding(for: segments)
            let firstSeen = segments.map(\.start).min() ?? .greatestFiniteMagnitude
            let spans = segments.compactMap { segment -> Range<TimeInterval>? in
                let start = windowStart + segment.start
                let end = windowStart + segment.end
                return end > start ? start..<end : nil
            }
            return LocalObservation(
                localID: localID,
                duration: duration,
                firstSeen: firstSeen,
                embedding: embedding,
                spans: spans
            )
        }
        .sorted {
            if $0.firstSeen == $1.firstSeen { return $0.localID < $1.localID }
            return $0.firstSeen < $1.firstSeen
        }
    }

    private static func representativeEmbedding(for segments: [DiarizedSegment]) -> [Float]? {
        let valid = segments.filter { validEmbedding($0.embedding) }
        guard let first = valid.first else { return nil }
        let dimension = first.embedding.count
        guard valid.allSatisfy({ $0.embedding.count == dimension }) else { return nil }

        var sum = [Float](repeating: 0, count: dimension)
        var totalWeight: Float = 0
        for segment in valid {
            let weight = Float(max(segment.duration, 0.001))
            for index in 0..<dimension {
                sum[index] += segment.embedding[index] * weight
            }
            totalWeight += weight
        }
        guard totalWeight > 0 else { return nil }
        for index in sum.indices { sum[index] /= totalWeight }
        return normalized(sum)
    }

    // MARK: - Global assignment

    private static func assign(
        _ observations: [LocalObservation],
        to clusters: inout [GlobalCluster],
        birthSimilarity: inout [String: Float],
        supersededSeeds: inout [String: [String]]
    ) -> [String: String] {
        var map: [String: String] = [:]
        var unmatched = observations

        // Atribuição 1:1 exata, CARDINALIDADE primeiro (ver `optimalAssignment`).
        let pairs = optimalMatches(observations: observations, clusters: clusters)
        for pair in pairs {
            let observation = observations[pair.observationIndex]
            guard map[observation.localID] == nil else { continue }
            map[observation.localID] = clusters[pair.clusterIndex].id
            update(&clusters[pair.clusterIndex], with: observation)
            unmatched.removeAll { $0.localID == observation.localID }
        }

        // A high-similarity duplicate is allowed to reuse an already occupied global identity.
        // This is the only intentional many-to-one path: it handles one voice split into two
        // local slots without allowing arbitrary borderline observations to steal a free slot.
        for observation in unmatched {
            guard let match = bestCluster(
                for: observation,
                in: clusters,
                minimumSimilarity: duplicateFragmentSimilarity
            ) else { continue }
            map[observation.localID] = clusters[match.index].id
            update(&clusters[match.index], with: observation)
        }
        unmatched.removeAll { map[$0.localID] != nil }

        // The same gates apply to the first window and every later window. Only evidence that
        // increases the number of voices, lasts >= 2 s, and is clearly separated from every
        // existing centroid may create a global cluster. Anything in the uncertainty band is
        // deliberately left unassigned instead of being force-fused or becoming a ghost speaker.
        // The one exception is a weak seed: see `holdsUncertaintyBand`.
        for observation in unmatched {
            // A new cluster created earlier in this same pass can still absorb an unmistakable
            // duplicate local slot. This keeps the anti-fragmentation path without weakening the
            // minimum match threshold for a genuinely new observation.
            if let duplicate = bestCluster(
                for: observation,
                in: clusters,
                minimumSimilarity: duplicateFragmentSimilarity
            ) {
                map[observation.localID] = clusters[duplicate.index].id
                update(&clusters[duplicate.index], with: observation)
                continue
            }

            // Sementes fracas que esta observação supera na faixa de incerteza
            // ficam fora do gate; o resto conta como sempre.
            var seeds: [String] = []
            var bestSimilarity: Float = -1
            for cluster in clusters {
                guard let similarity = cosineSimilarity(observation.embedding, cluster.centroid) else { continue }
                if similarity >= newClusterMaximumSimilarity,
                   !holdsUncertaintyBand(cluster, against: observation, similarity: similarity) {
                    seeds.append(cluster.id)
                } else {
                    bestSimilarity = max(bestSimilarity, similarity)
                }
            }

            if observation.duration >= minimumNewClusterDuration,
               bestSimilarity < newClusterMaximumSimilarity {
                let cluster = makeCluster(index: clusters.count, observation: observation)
                map[observation.localID] = cluster.id
                birthSimilarity[cluster.id] = bestSimilarity
                if !seeds.isEmpty { supersededSeeds[cluster.id] = seeds }
                clusters.append(cluster)
            }
        }

        return map
    }

    /// Semente fraca — global com menos fala única que um participante
    /// apresentável — não segura a faixa de incerteza contra uma observação que
    /// sozinha já seria participante. Na planning de 12/10, a 3ª pessoa estreou
    /// com 7,5 s ruidosos; a fala longa dela dava 0,76 contra essa semente (não
    /// liga, não cria) e ficou sem dono por 25 min, até a semente ser rebaixada
    /// e a pessoa sumir. A semente não é absorvida: continua existindo e, curta,
    /// é rebaixada. Participante estabelecido e casamento (≥ 0,78) seguem
    /// segurando sempre. A força da semente é a união dos trechos, não a soma:
    /// os mesmos 7,5 s vistos pelas duas janelas da sobreposição não viram 15 s.
    private static func holdsUncertaintyBand(
        _ cluster: GlobalCluster,
        against observation: LocalObservation,
        similarity: Float
    ) -> Bool {
        similarity >= clusterMatchSimilarity
            || observation.duration < minimumPresentedClusterDuration
            || cluster.speechDuration >= minimumPresentedClusterDuration
    }

    private struct Candidate {
        let observationIndex: Int
        let clusterIndex: Int
        let similarity: Float
    }

    /// Peso que faz a CARDINALIDADE vir antes da soma. Maior que qualquer soma
    /// de similaridades possível (cada aresta vale ≤ 1), então um par a mais
    /// sempre vence qualquer ganho de soma.
    static let cardinalityWeight: Double = 1_000_000

    /// Atribuição 1:1 ótima entre observações locais e clusters globais, com
    /// objetivo CARDINALIDADE-PRIMEIRO: maximiza o NÚMERO de pares com
    /// similaridade ≥ `minimumSimilarity` e usa a soma só como desempate.
    ///
    /// O objetivo anterior era a soma pura, e a soma prefere quatro arestas 1,0
    /// a cinco arestas 0,78 — deixando uma voz que TINHA aresta válida sem
    /// atribuição, que é justamente a fronteira da Reunião de Equipe.
    ///
    /// Custo: Hungarian (Kuhn–Munkres com potenciais) — O(n²·m), n = min(obs,
    /// clusters), m = max. A busca por subconjuntos memoizada que estava aqui
    /// era O(N·M·2^M) em tempo e O(N·2^M) em memória, e nem N nem M têm teto no
    /// pipeline: `OfflineDiarizerConfig.default` deixa `maxSpeakers` nulo e os
    /// globais crescem com a duração da reunião (39 janelas em 79 min).
    ///
    /// `similarities[observação][cluster]`; `nil` = sem embedding comparável.
    /// Devolve observação → cluster. Exposta para teste com a matriz direta.
    static func optimalAssignment(
        similarities: [[Float?]],
        minimumSimilarity: Float = clusterMatchSimilarity
    ) -> [Int: Int] {
        let observationCount = similarities.count
        guard observationCount > 0 else { return [:] }
        let clusterCount = similarities.map(\.count).max() ?? 0
        guard clusterCount > 0 else { return [:] }

        func profit(observation: Int, cluster: Int) -> Double {
            guard cluster < similarities[observation].count,
                  let similarity = similarities[observation][cluster],
                  similarity >= minimumSimilarity
            else { return 0 }
            return cardinalityWeight + Double(similarity)
        }

        // O Hungarian exige linhas ≤ colunas.
        let transposed = observationCount > clusterCount
        let rows = transposed ? clusterCount : observationCount
        let columns = transposed ? observationCount : clusterCount
        var cost = [[Double]](repeating: [Double](repeating: 0, count: columns), count: rows)
        for row in 0..<rows {
            for column in 0..<columns {
                let observation = transposed ? column : row
                let cluster = transposed ? row : column
                cost[row][column] = -profit(observation: observation, cluster: cluster)
            }
        }

        var result: [Int: Int] = [:]
        for (row, column) in hungarian(cost: cost).enumerated() where column >= 0 {
            let observation = transposed ? column : row
            let cluster = transposed ? row : column
            // Aresta inválida (lucro 0) entra no matching só para completar a
            // permutação; não é atribuição.
            guard profit(observation: observation, cluster: cluster) > 0 else { continue }
            result[observation] = cluster
        }
        return result
    }

    /// Kuhn–Munkres com potenciais (custo MÍNIMO). `cost` tem linhas ≤ colunas.
    /// Devolve, por linha, a coluna atribuída (-1 quando não houver).
    private static func hungarian(cost: [[Double]]) -> [Int] {
        let rows = cost.count
        guard rows > 0, let columns = cost.first?.count, columns >= rows else {
            return [Int](repeating: -1, count: rows)
        }
        // Finito de propósito: `greatestFiniteMagnitude` menos delta ainda é
        // finito, mas somar potenciais infinitos envenena a matriz.
        let infinity = 1e18

        var u = [Double](repeating: 0, count: rows + 1)
        var v = [Double](repeating: 0, count: columns + 1)
        var assignedRow = [Int](repeating: 0, count: columns + 1)
        var way = [Int](repeating: 0, count: columns + 1)

        for row in 1...rows {
            assignedRow[0] = row
            var column = 0
            var minimum = [Double](repeating: infinity, count: columns + 1)
            var used = [Bool](repeating: false, count: columns + 1)
            repeat {
                used[column] = true
                let currentRow = assignedRow[column]
                var delta = infinity
                var nextColumn = 0
                for candidate in 1...columns where !used[candidate] {
                    let reduced = cost[currentRow - 1][candidate - 1] - u[currentRow] - v[candidate]
                    if reduced < minimum[candidate] {
                        minimum[candidate] = reduced
                        way[candidate] = column
                    }
                    if minimum[candidate] < delta {
                        delta = minimum[candidate]
                        nextColumn = candidate
                    }
                }
                for candidate in 0...columns {
                    if used[candidate] {
                        u[assignedRow[candidate]] += delta
                        v[candidate] -= delta
                    } else {
                        minimum[candidate] -= delta
                    }
                }
                column = nextColumn
            } while assignedRow[column] != 0

            repeat {
                let previous = way[column]
                assignedRow[column] = assignedRow[previous]
                column = previous
            } while column != 0
        }

        var assignment = [Int](repeating: -1, count: rows)
        for column in 1...columns where assignedRow[column] != 0 {
            assignment[assignedRow[column] - 1] = column - 1
        }
        return assignment
    }

    private static func optimalMatches(
        observations: [LocalObservation],
        clusters: [GlobalCluster]
    ) -> [Candidate] {
        guard !observations.isEmpty, !clusters.isEmpty else { return [] }

        let similarities: [[Float?]] = observations.map { observation in
            clusters.map { cosineSimilarity(observation.embedding, $0.centroid) }
        }

        return optimalAssignment(similarities: similarities)
            .map { observationIndex, clusterIndex in
                Candidate(
                    observationIndex: observationIndex,
                    clusterIndex: clusterIndex,
                    similarity: similarities[observationIndex][clusterIndex] ?? 0
                )
            }
            .sorted {
                if $0.observationIndex == $1.observationIndex {
                    return $0.clusterIndex < $1.clusterIndex
                }
                return $0.observationIndex < $1.observationIndex
            }
    }

    private static func bestCluster(
        for observation: LocalObservation,
        in clusters: [GlobalCluster],
        minimumSimilarity: Float
    ) -> (index: Int, similarity: Float)? {
        clusters.indices.compactMap { index in
            guard let similarity = cosineSimilarity(observation.embedding, clusters[index].centroid),
                  similarity >= minimumSimilarity
            else { return nil }
            return (index, similarity)
        }
        .max {
            if $0.similarity == $1.similarity { return $0.index > $1.index }
            return $0.similarity < $1.similarity
        }
    }

    private static func makeCluster(index: Int, observation: LocalObservation) -> GlobalCluster {
        GlobalCluster(
            id: "S\(index + 1)",
            spans: observation.spans,
            embeddingWeight: max(observation.duration, 0.001),
            centroid: observation.embedding,
            firstSeen: observation.firstSeen
        )
    }

    private static func update(
        _ cluster: inout GlobalCluster,
        with observation: LocalObservation
    ) {
        let weight = max(observation.duration, 0.001)

        if let current = cluster.centroid,
           let incoming = observation.embedding,
           current.count == incoming.count {
            var blended = [Float](repeating: 0, count: current.count)
            let oldWeight = Float(max(cluster.embeddingWeight, 0.001))
            let newWeight = Float(weight)
            for index in blended.indices {
                blended[index] = (current[index] * oldWeight + incoming[index] * newWeight)
                    / (oldWeight + newWeight)
            }
            cluster.centroid = normalized(blended)
            cluster.embeddingWeight += weight
        } else if cluster.centroid == nil {
            cluster.centroid = observation.embedding
            cluster.embeddingWeight = weight
        }
        cluster.spans += observation.spans
    }

    // MARK: - Timeline materialization

    /// Um segmento materializado com a janela e o slot local que o DETECTARAM.
    /// A proveniência é o que faz `windowCountByCluster` distinguir fragmento
    /// de voz real, e o que deixa a religação final achar a fala de uma
    /// observação sem dono.
    private struct MaterializedSegment {
        var segment: DiarizedSegment
        var windowIndex: Int
        var localID: String
    }

    private static func materialize(
        _ results: [DiarizationWindowResult],
        assignments: [Int: [String: String]],
        globalLinkingEnabled: Bool,
        globalCentroids: [String: [Float]]
    ) -> [MaterializedSegment] {
        let ordered = results.sorted { $0.window.index < $1.window.index }
        var materialized: [MaterializedSegment] = []

        for (position, result) in ordered.enumerated() {
            let assignment = assignments[result.window.index] ?? [:]
            for segment in result.segments {
                let start = result.window.start + segment.start
                let end = result.window.start + segment.end
                guard end > start else { continue }

                // Recorte por SUB-REGIÃO (ver `clipping(_:against:...)`).
                var pieces = [start..<end]
                if position > ordered.startIndex {
                    pieces = clipping(
                        pieces,
                        against: ordered[ordered.index(before: position)],
                        window: result.window,
                        ownsAfterMidpoint: true
                    )
                }
                if position + 1 < ordered.count {
                    pieces = clipping(
                        pieces,
                        against: ordered[ordered.index(after: position)],
                        window: result.window,
                        ownsAfterMidpoint: false
                    )
                }
                guard !pieces.isEmpty else { continue }

                let speakerID: String
                let embedding: [Float]
                if globalLinkingEnabled {
                    // Sem atribuição = faixa de incerteza ou curta demais. Sai
                    // com o sentinela em vez de sumir: quem consome precisa
                    // saber que houve fala ali sem identidade — omitir isso
                    // transformava não-atribuído em atribuição errada.
                    if let assignedSpeakerID = assignment[segment.speakerId] {
                        speakerID = assignedSpeakerID
                        // MeetingViewModel already persists the embedding of the longest returned
                        // segment in MeetingSpeaker.embedding. Returning the final global centroid on
                        // every segment makes that existing path persist the centroid, while keeping
                        // old MeetingSpeaker Codable data (where embedding may be absent) compatible.
                        embedding = globalCentroids[assignedSpeakerID] ?? segment.embedding
                    } else {
                        speakerID = DiarizedSegment.unassignedSpeakerId
                        embedding = segment.embedding
                    }
                } else {
                    speakerID = segment.speakerId
                    embedding = segment.embedding
                }

                for piece in pieces {
                    materialized.append(
                        MaterializedSegment(
                            segment: DiarizedSegment(
                                speakerId: speakerID,
                                start: piece.lowerBound,
                                end: piece.upperBound,
                                embedding: embedding
                            ),
                            windowIndex: result.window.index,
                            localID: segment.speakerId
                        )
                    )
                }
            }
        }

        return materialized
    }

    /// Recorte por SUB-REGIÃO contra um vizinho.
    ///
    /// O midpoint existe para desempatar DUPLICATA: só faz sentido onde as duas
    /// janelas viram a mesma fala. Decidir por janela (qualquer fala em qualquer
    /// ponto do overlap) apagava detecção de um lado só; decidir pelo SEGMENTO
    /// inteiro ainda apagava a cauda unilateral de um segmento parcialmente
    /// compartilhado — esquerda vendo [130,170] e direita só [130,140] perdia
    /// [150,170]. Aqui o segmento é dividido: as sub-regiões que o vizinho
    /// também viu vão ao midpoint, e o resto fica inteiro com quem viu.
    ///
    /// `ownsAfterMidpoint` = esta janela fica com a metade DEPOIS do corte (o
    /// vizinho é o anterior); false = fica com a metade antes.
    private static func clipping(
        _ intervals: [Range<TimeInterval>],
        against neighbour: DiarizationWindowResult,
        window: DiarizationWindow,
        ownsAfterMidpoint: Bool
    ) -> [Range<TimeInterval>] {
        let overlapStart = max(window.start, neighbour.window.start)
        let overlapEnd = min(window.end, neighbour.window.end)
        guard overlapEnd > overlapStart else { return intervals }
        let midpoint = (overlapStart + overlapEnd) / 2

        let seen = normalizedUnion(
            neighbour.segments.compactMap { segment -> Range<TimeInterval>? in
                let start = max(neighbour.window.start + segment.start, overlapStart)
                let end = min(neighbour.window.start + segment.end, overlapEnd)
                return end > start ? start..<end : nil
            }
        )
        guard !seen.isEmpty else { return intervals }

        var result: [Range<TimeInterval>] = []
        for interval in intervals {
            // O que só esta janela viu passa inteiro.
            result.append(contentsOf: subtracting(seen, from: interval))
            // O compartilhado vai ao midpoint.
            for shared in intersecting(interval, with: seen) {
                let lower = ownsAfterMidpoint ? max(shared.lowerBound, midpoint) : shared.lowerBound
                let upper = ownsAfterMidpoint ? shared.upperBound : min(shared.upperBound, midpoint)
                if upper > lower { result.append(lower..<upper) }
            }
        }
        return normalizedUnion(result)
    }

    private static func normalizedUnion(_ ranges: [Range<TimeInterval>]) -> [Range<TimeInterval>] {
        let sorted = ranges.filter { $0.upperBound > $0.lowerBound }
            .sorted { $0.lowerBound < $1.lowerBound }
        guard var current = sorted.first else { return [] }
        var merged: [Range<TimeInterval>] = []
        for range in sorted.dropFirst() {
            if range.lowerBound > current.upperBound {
                merged.append(current)
                current = range
            } else {
                current = current.lowerBound..<max(current.upperBound, range.upperBound)
            }
        }
        merged.append(current)
        return merged
    }

    private static func intersecting(
        _ interval: Range<TimeInterval>,
        with spans: [Range<TimeInterval>]
    ) -> [Range<TimeInterval>] {
        spans.compactMap { span in
            let lower = max(interval.lowerBound, span.lowerBound)
            let upper = min(interval.upperBound, span.upperBound)
            return upper > lower ? lower..<upper : nil
        }
    }

    private static func subtracting(
        _ spans: [Range<TimeInterval>],
        from interval: Range<TimeInterval>
    ) -> [Range<TimeInterval>] {
        var remaining: [Range<TimeInterval>] = []
        var cursor = interval.lowerBound
        for span in intersecting(interval, with: spans).sorted(by: { $0.lowerBound < $1.lowerBound }) {
            if span.lowerBound > cursor { remaining.append(cursor..<span.lowerBound) }
            cursor = max(cursor, span.upperBound)
        }
        if cursor < interval.upperBound { remaining.append(cursor..<interval.upperBound) }
        return remaining
    }

    // MARK: - Final global reconciliation

    /// Passagem final global-global. Um global criado cedo — quando o único
    /// vizinho estava abaixo de 0,60 — nunca é reavaliado contra os que
    /// nasceram depois, e dois fragmentos da mesma voz atravessam a reunião
    /// como participantes distintos. Aqui os centroides finais (bem mais
    /// informados que os de nascimento) se comparam entre si com a MESMA barra
    /// alta de duplicata (0,88): funde só o que é inequívoco.
    ///
    /// Devolve removido → mantido, já transitivo. O mantido é o mais antigo:
    /// os clusters são criados em ordem de aparição.
    private static func reconcile(
        _ clusters: inout [GlobalCluster],
        coOccurrence: [String: Set<String>]
    ) -> [String: String] {
        var merges: [String: String] = [:]
        var together = coOccurrence
        var didMerge = true

        while didMerge {
            didMerge = false
            search: for keep in clusters.indices {
                for drop in clusters.indices where drop > keep {
                    // Coocorreram numa janela ⇒ são duas pessoas, e similaridade
                    // alta entre elas só quer dizer que têm vozes parecidas.
                    // Fundir aqui apagaria um participante real.
                    guard together[clusters[keep].id]?.contains(clusters[drop].id) != true
                    else { continue }
                    guard let similarity = cosineSimilarity(
                        clusters[keep].centroid,
                        clusters[drop].centroid
                    ), similarity >= duplicateFragmentSimilarity else { continue }

                    let removedID = clusters[drop].id
                    let keptID = clusters[keep].id
                    merges[removedID] = keptID
                    for (from, to) in merges where to == removedID {
                        merges[from] = keptID
                    }
                    // O fundido herda as incompatibilidades do removido.
                    let inherited = together[removedID] ?? []
                    together[keptID, default: []].formUnion(inherited)
                    for other in inherited {
                        together[other, default: []].insert(keptID)
                        together[other]?.remove(removedID)
                    }
                    together[removedID] = nil

                    absorb(&clusters[keep], clusters[drop])
                    clusters.remove(at: drop)
                    didMerge = true
                    break search
                }
            }
        }
        return merges
    }

    private static func absorb(_ cluster: inout GlobalCluster, _ other: GlobalCluster) {
        if let current = cluster.centroid,
           let incoming = other.centroid,
           current.count == incoming.count {
            let oldWeight = Float(max(cluster.embeddingWeight, 0.001))
            let newWeight = Float(max(other.embeddingWeight, 0.001))
            var blended = [Float](repeating: 0, count: current.count)
            for index in blended.indices {
                blended[index] = (current[index] * oldWeight + incoming[index] * newWeight)
                    / (oldWeight + newWeight)
            }
            cluster.centroid = normalized(blended)
        } else if cluster.centroid == nil {
            cluster.centroid = other.centroid
        }
        cluster.embeddingWeight += other.embeddingWeight
        cluster.spans += other.spans
    }

    // MARK: - Final relink of unassigned speech

    /// Passagem final observação-global. A atribuição compara cada observação
    /// com o centroide que o participante tinha NAQUELA janela, ainda pouco
    /// informado. Na planning de 12/10, 69 s da janela 27 davam 0,74 contra
    /// esse centroide (faixa de incerteza: sem dono) e 0,86 contra o centroide
    /// final do mesmo participante.
    ///
    /// Aqui a observação sem dono se compara aos centroides FINAIS, com as
    /// barras da atribuição: 0,78 com quem está livre na janela e 0,88
    /// (duplicata) com quem já a ocupa — a regra 1:1 continua valendo. Só
    /// participante apresentado recebe fala: a passagem não cria participante,
    /// não ressuscita semente rebaixada e não tira fala de ninguém. Os
    /// centroides não mudam, então a ordem das janelas não importa.
    ///
    /// Apresentado é quem sobreviveu ao rebaixamento, na linha do tempo, e não
    /// `speechDuration`: na sobreposição, o corte no meio dá parte dos trechos
    /// à janela vizinha. Na planning, um global com 24,8 s de trechos fica com
    /// 1,2 s e é rebaixado.
    ///
    /// Devolve participante → duração religada.
    private static func relinkUnassigned(
        _ materialized: inout [MaterializedSegment],
        observationsByWindow: [Int: [LocalObservation]],
        assignments: [Int: [String: String]],
        clusters: [GlobalCluster]
    ) -> [String: TimeInterval] {
        // Depois do rebaixamento, só participante apresentado segue atribuído.
        let presented = Set(materialized.filter(\.segment.isAssigned).map(\.segment.speakerId))
        let targets = clusters.filter { presented.contains($0.id) }
        guard !targets.isEmpty else { return [:] }

        // Só disputa quem tem fala sem dono na linha do tempo DESTA janela. A
        // observação que a vizinha cobre (corte no meio da sobreposição) não
        // sobra aqui: religá-la não muda segmento nenhum, e ela tiraria o
        // participante de quem sobrou. A fala dela se decide na vizinha.
        var unassignedSpeech: [Int: Set<String>] = [:]
        for entry in materialized where !entry.segment.isAssigned {
            unassignedSpeech[entry.windowIndex, default: []].insert(entry.localID)
        }

        var relinked: [Int: [String: String]] = [:]
        for (windowIndex, observations) in observationsByWindow {
            let assignment = assignments[windowIndex] ?? [:]
            let visible = unassignedSpeech[windowIndex] ?? []
            let pending = observations.filter {
                assignment[$0.localID] == nil && visible.contains($0.localID)
            }
            guard !pending.isEmpty else { continue }

            var map: [String: String] = [:]
            // 1:1 com quem está livre na janela, na barra de casamento.
            let occupied = Set(assignment.values)
            let free = targets.filter { !occupied.contains($0.id) }
            for pair in optimalMatches(observations: pending, clusters: free) {
                map[pending[pair.observationIndex].localID] = free[pair.clusterIndex].id
            }
            // Quem já ocupa a janela, antes ou agora, só leva duplicata.
            for observation in pending where map[observation.localID] == nil {
                guard let match = bestCluster(
                    for: observation,
                    in: targets,
                    minimumSimilarity: duplicateFragmentSimilarity
                ) else { continue }
                map[observation.localID] = targets[match.index].id
            }
            if !map.isEmpty { relinked[windowIndex] = map }
        }
        guard !relinked.isEmpty else { return [:] }

        let centroids = Dictionary(uniqueKeysWithValues: targets.compactMap { cluster in
            cluster.centroid.map { (cluster.id, $0) }
        })
        var spansByCluster: [String: [Range<TimeInterval>]] = [:]
        for index in materialized.indices {
            let entry = materialized[index]
            guard !entry.segment.isAssigned,
                  let clusterID = relinked[entry.windowIndex]?[entry.localID]
            else { continue }
            materialized[index].segment = DiarizedSegment(
                speakerId: clusterID,
                start: entry.segment.start,
                end: entry.segment.end,
                embedding: centroids[clusterID] ?? entry.segment.embedding
            )
            spansByCluster[clusterID, default: []].append(entry.segment.start..<entry.segment.end)
        }
        return spansByCluster.mapValues { unionDuration($0) }
    }

    private static func mergeAdjacent(_ segments: [DiarizedSegment]) -> [DiarizedSegment] {
        let sorted = segments.sorted {
            if $0.start == $1.start { return $0.end < $1.end }
            return $0.start < $1.start
        }
        guard var current = sorted.first else { return [] }
        var merged: [DiarizedSegment] = []

        for segment in sorted.dropFirst() {
            let gap = segment.start - current.end
            if segment.speakerId == current.speakerId, gap <= mergeGap {
                current = DiarizedSegment(
                    speakerId: current.speakerId,
                    start: current.start,
                    end: max(current.end, segment.end),
                    embedding: current.embedding
                )
            } else {
                merged.append(current)
                current = segment
            }
        }
        merged.append(current)
        return merged
    }

    private static func validEmbedding(_ embedding: [Float]) -> Bool {
        !embedding.isEmpty && embedding.allSatisfy { $0.isFinite }
    }

    private static func normalized(_ embedding: [Float]) -> [Float]? {
        guard validEmbedding(embedding) else { return nil }
        let magnitude = sqrt(embedding.reduce(0) { $0 + ($1 * $1) })
        guard magnitude > 0, magnitude.isFinite else { return nil }
        return embedding.map { $0 / magnitude }
    }

    private static func cosineSimilarity(
        _ lhs: [Float]?,
        _ rhs: [Float]?
    ) -> Float? {
        guard let lhs, let rhs, lhs.count == rhs.count,
              let normalizedLHS = normalized(lhs),
              let normalizedRHS = normalized(rhs)
        else { return nil }
        let dot = zip(normalizedLHS, normalizedRHS).reduce(Float.zero) { $0 + ($1.0 * $1.1) }
        return min(1, max(-1, dot))
    }
}

/// Cortes de lote vindos da diarização.
///
/// O lote do `MeetingRecordedAudioBatchReader` fecha por silêncio (≥0,6 s) ou
/// pelo teto de 28 s. Quando o mic cala e o system fala sem pausa, a
/// fronteira nunca cai na troca de falante: pergunta e resposta viram um
/// bloco só, e o `applyDiarization` — que atribui o turno INTEIRO ao cluster
/// dominante — dá o bloco todo para quem falou mais. Foi assim que 163 dos
/// 302 turnos da sessão de referência saíram com exatos 26 s.
///
/// A diarização roda ANTES da transcrição (13 s para 79 min) e as trocas de
/// falante entram como corte OBRIGATÓRIO, ao lado do silêncio e do teto.
/// Cada lote nasce de um falante só e a atribuição vira exata.
nonisolated enum DiarizationBatchCuts {
    /// Cortes mais próximos que isto viram um lote curto demais para o ASR,
    /// e a troca de falante nessa escala é ruído de diarização.
    static let defaultMinimumSpacing: TimeInterval = 1

    /// As bordas de fala da diarização, ordenadas e sem repetição.
    ///
    /// Início E fim de cada segmento: o silêncio entre dois segmentos do
    /// MESMO falante também é fronteira útil, e a saída de fala é o que
    /// separa o eco da resposta no canal do mic.
    ///
    /// O sentinela (`DiarizedSegment.unassignedSpeakerId`) entra como
    /// qualquer outro: é fala detectada, e a entrada ou saída dela também é
    /// troca de falante.
    static func batchBoundaries(
        from segments: [DiarizedSegment],
        minimumSpacing: TimeInterval = defaultMinimumSpacing
    ) -> [TimeInterval] {
        let edges = segments
            .flatMap { [$0.start, $0.end] }
            .filter { $0 > 0 && $0.isFinite }
            .sorted()
        var kept: [TimeInterval] = []
        for edge in edges {
            if let last = kept.last, edge - last < minimumSpacing { continue }
            kept.append(edge)
        }
        return kept
    }
}

/// Atribuição de um turn do transcript a um cluster global. Vive aqui, e não no
/// `MeetingViewModel`, porque é decisão pura — e porque foi exatamente aqui que
/// "não-atribuído" virava "atribuído errado".
enum DiarizationTurnAttribution {
    /// Distância máxima até o segmento mais próximo quando o turn não sobrepõe
    /// nenhum. Sem teto, um turn isolado era empurrado para o segmento mais
    /// próximo mesmo a minutos de distância — e recebia o participante errado.
    /// ~2 s cobre desalinhamento de fronteira entre o VAD do ASR e o do
    /// diarizador; acima disso não há evidência, e sem evidência não se atribui.
    static let maximumFallbackDistance: TimeInterval = 2

    /// Cluster dominante do turn, ou `nil` quando não há evidência.
    ///
    /// O sentinela participa do julgamento (é fala detectada) mas nunca vira
    /// atribuição: se quem mais cobre o turn é fala sem identidade, o turn
    /// mantém o que já tinha. Preferir o segundo colocado seria roubar o
    /// vizinho, que é o defeito que o sentinela existe para impedir.
    static func dominantCluster(
        start: TimeInterval,
        end: TimeInterval,
        segments: [DiarizedSegment],
        maximumFallbackDistance: TimeInterval = maximumFallbackDistance
    ) -> String? {
        var overlapBySpeaker: [String: TimeInterval] = [:]
        for segment in segments {
            let overlap = min(end, segment.end) - max(start, segment.start)
            if overlap > 0 {
                overlapBySpeaker[segment.speakerId, default: 0] += overlap
            }
        }
        // Empate resolve pelo menor ID, o que faz um cluster real ganhar do
        // sentinela ("S…" < "__unassigned__"): com cobertura idêntica, a
        // evidência com identidade é a que manda. Determinístico de propósito —
        // `max` sobre dicionário sem desempate depende da ordem do hash.
        if let best = overlapBySpeaker.max(by: {
            if $0.value == $1.value { return $0.key > $1.key }
            return $0.value < $1.value
        }) {
            return best.key == DiarizedSegment.unassignedSpeakerId ? nil : best.key
        }

        // Sem sobreposição: o segmento mais próximo, e só dentro do teto.
        let nearest = segments.min { lhs, rhs in
            let left = distance(from: lhs, toTurnFrom: start, to: end)
            let right = distance(from: rhs, toTurnFrom: start, to: end)
            if left == right { return lhs.start < rhs.start }
            return left < right
        }
        guard let nearest,
              distance(from: nearest, toTurnFrom: start, to: end) <= maximumFallbackDistance,
              nearest.isAssigned
        else { return nil }
        return nearest.speakerId
    }

    /// Distância entre o turn e o segmento (0 se encostam ou se sobrepõem).
    private static func distance(
        from segment: DiarizedSegment,
        toTurnFrom start: TimeInterval,
        to end: TimeInterval
    ) -> TimeInterval {
        max(0, max(segment.start - end, start - segment.end))
    }
}
