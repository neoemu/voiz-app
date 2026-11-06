import Foundation
import Testing

@Suite("Reunião — diarização em janelas e costura global")
struct MeetingDiarizationWindowLinkerTests {

    @Test("Planeja janelas de 3 min com 60 s de sobreposição")
    func plansThreeMinuteWindows() {
        let windows = DiarizationWindowPlanner.makeWindows(duration: 420)

        #expect(windows.map(\.start) == [0, 120, 240])
        #expect(windows.map(\.end) == [180, 300, 420])
    }

    @Test("Costura um mesmo falante que troca de ID na janela seguinte")
    func stitchesWindowBoundary() {
        let results = [
            result(
                index: 0,
                start: 0,
                end: 180,
                segments: [segment("local-A", start: 130, end: 160, embedding: [1, 0])]
            ),
            result(
                index: 1,
                start: 120,
                end: 300,
                segments: [segment("local-Z", start: 10, end: 40, embedding: [0.999, 0.02])]
            )
        ]

        let stitched = DiarizationWindowLinker.link(results)

        #expect(stitched.count == 1)
        #expect(stitched.first?.speakerId == "S1")
        #expect(stitched.first?.start == 130)
        #expect(stitched.first?.end == 160)
    }

    @Test("Aplica o limiar: embedding próximo funde, embedding ortogonal é novo")
    func appliesSimilarityCriterion() {
        let results = [
            result(
                index: 0,
                start: 0,
                end: 180,
                segments: [
                    segment("first-A", start: 0, end: 20, embedding: [1, 0]),
                    segment("first-B", start: 30, end: 50, embedding: [0, 1])
                ]
            ),
            result(
                index: 1,
                start: 120,
                end: 300,
                segments: [
                    segment("next-near-A", start: 40, end: 60, embedding: [0.8, 0.6]),
                    segment("next-near-B", start: 70, end: 90, embedding: [0.6, 0.8])
                ]
            )
        ]

        let linked = DiarizationWindowLinker.link(results)
        let idsByStart = Dictionary(uniqueKeysWithValues: linked.map { (Int($0.start), $0.speakerId) })

        #expect(idsByStart[0] == "S1")
        #expect(idsByStart[30] == "S2")
        #expect(idsByStart[160] == "S1")
        #expect(idsByStart[190] == "S2")
        #expect(Set(linked.map(\.speakerId)) == ["S1", "S2"])
    }

    @Test("Gate 1:1 não fragmenta mesmo se uma janela cria dois slots")
    func oneToOneDoesNotFragment() {
        let results = [
            result(
                index: 0,
                start: 0,
                end: 180,
                segments: [segment("first", start: 0, end: 40, embedding: [1, 0])]
            ),
            result(
                index: 1,
                start: 120,
                end: 300,
                segments: [
                    segment("split-1", start: 40, end: 50, embedding: [1, 0]),
                    // Above the duplicate threshold: a local split of the same voice may reuse
                    // the already occupied global identity without creating a participant.
                    segment("split-2", start: 50, end: 60, embedding: [0.9, 0.4358899])
                ]
            )
        ]

        let linked = DiarizationWindowLinker.link(results)

        #expect(Set(linked.map(\.speakerId)) == ["S1"])
        #expect(linked.reduce(0) { $0 + $1.duration } == 60)
    }

    @Test("Gate 1:3 preserva a fala minoritária e não colapsa")
    func oneToThreeDoesNotCollapse() {
        let results = [
            // A primeira janela representa o defeito medido: só o dominante aparece.
            result(
                index: 0,
                start: 0,
                end: 180,
                segments: [segment("collapsed-dominant", start: 0, end: 60, embedding: [1, 0, 0])]
            ),
            // A janela seguinte recupera as duas vozes remotas minoritárias.
            result(
                index: 1,
                start: 120,
                end: 300,
                segments: [
                    segment("next-dominant", start: 40, end: 60, embedding: [1, 0, 0]),
                    segment("next-minor-1", start: 70, end: 100, embedding: [0, 1, 0]),
                    segment("next-minor-2", start: 110, end: 140, embedding: [0, 0, 1])
                ]
            )
        ]

        let linked = DiarizationWindowLinker.link(results)

        #expect(Set(linked.map(\.speakerId)) == ["S1", "S2", "S3"])
        #expect(linked.filter { $0.speakerId != "S1" }.reduce(0) { $0 + $1.duration } == 60)
    }

    @Test("Sem costura global, a recuperação de identidade entre janelas falha")
    func disablingStitchingReintroducesIdentityDefect() {
        let results = [
            result(
                index: 0,
                start: 0,
                end: 180,
                segments: [
                    segment("S1", start: 0, end: 30, embedding: [1, 0]),
                    segment("S2", start: 40, end: 70, embedding: [0, 1])
                ]
            ),
            result(
                index: 1,
                start: 120,
                end: 300,
                segments: [
                    // Local IDs deliberately swap: only embeddings can recover the identity.
                    segment("S1", start: 40, end: 70, embedding: [0, 1]),
                    segment("S2", start: 80, end: 110, embedding: [1, 0])
                ]
            )
        ]

        let stitched = DiarizationWindowLinker.link(results)
        let unstitched = DiarizationWindowLinker.link(results, globalLinkingEnabled: false)

        let stitchedMinorIDs = Set(stitched.filter { $0.start >= 40 && $0.start < 100 }.map(\.speakerId))
        let unstitchedMinorIDs = Set(unstitched.filter { $0.start >= 40 && $0.start < 200 }.map(\.speakerId))

        #expect(stitchedMinorIDs == ["S2"])
        #expect(unstitchedMinorIDs.count == 2)
    }

    @Test("Voz nova não ocupa à força o slot livre de outra voz")
    func newVoiceDoesNotUseFreeClusterSlot() {
        let results = [
            result(
                index: 0,
                start: 0,
                end: 180,
                segments: [segment("only-A", start: 0, end: 20, embedding: [1, 0])]
            ),
            result(
                index: 1,
                start: 120,
                end: 300,
                segments: [segment("new-C", start: 40, end: 70, embedding: [0, 1])]
            )
        ]

        let linked = DiarizationWindowLinker.link(results)

        #expect(Set(linked.map(\.speakerId)) == ["S1", "S2"])
        #expect(linked.first(where: { $0.start == 160 })?.speakerId == "S2")
    }

    @Test("Gate de duração também vale para a primeira janela")
    func firstWindowUsesDurationGate() {
        let results = [
            result(
                index: 0,
                start: 0,
                end: 180,
                segments: [segment("ghost", start: 0, end: 0.1, embedding: [1, 0])]
            ),
            result(
                index: 1,
                start: 120,
                end: 300,
                segments: [segment("real", start: 40, end: 70, embedding: [0, 1])]
            )
        ]

        let linked = DiarizationWindowLinker.link(results)
        let assigned = linked.filter(\.isAssigned)

        #expect(assigned.count == 1)
        #expect(assigned.first?.speakerId == "S1")
        #expect(assigned.first?.start == 160)
        // O blip de 0,1 s não vira participante — mas também não some: sai como
        // sentinela, senão o applyDiarization empurra o turn para o vizinho.
        let ghost = linked.filter { !$0.isAssigned }
        #expect(ghost.count == 1)
        #expect(ghost.first?.speakerId == DiarizedSegment.unassignedSpeakerId)
        #expect(ghost.first?.start == 0)
    }

    @Test("Ownership preserva fala detectada por apenas um lado do overlap")
    func oneSidedOwnershipKeepsWholeSegment() {
        let seenOnlyByLeft = DiarizationWindowLinker.link([
            result(
                index: 0,
                start: 0,
                end: 180,
                segments: [segment("left", start: 130, end: 170, embedding: [1, 0])]
            ),
            result(index: 1, start: 120, end: 300, segments: [])
        ])
        let seenOnlyByRight = DiarizationWindowLinker.link([
            result(index: 0, start: 0, end: 180, segments: []),
            result(
                index: 1,
                start: 120,
                end: 300,
                segments: [segment("right", start: 10, end: 50, embedding: [1, 0])]
            )
        ])

        #expect(seenOnlyByLeft.count == 1)
        #expect(seenOnlyByLeft.first?.start == 130)
        #expect(seenOnlyByLeft.first?.end == 170)
        #expect(seenOnlyByRight.count == 1)
        #expect(seenOnlyByRight.first?.start == 130)
        #expect(seenOnlyByRight.first?.end == 170)
    }

    @Test("Matching ótimo evita que a maior aresta roube o par global")
    func optimalMatchingAvoidsGreedyTheft() {
        // The first window has three clearly separated centroids (pairwise cosine = 0.50).
        // In the next window, B→S2 is the largest single edge (0.92), but the global optimum is
        // A→S2 (0.87) + B→S1 (0.80); greedy would drop A.
        let results = [
            result(
                index: 0,
                start: 0,
                end: 180,
                segments: [
                    segment("first-A", start: 0, end: 20, embedding: [1, 0, 0]),
                    segment("first-B", start: 30, end: 50, embedding: [0.5, 0.8660254, 0]),
                    segment("first-C", start: 60, end: 80, embedding: [0.5, 0.2886751, 0.8164966])
                ]
            ),
            result(
                index: 1,
                start: 120,
                end: 300,
                segments: [
                    segment("next-A", start: 40, end: 60, embedding: [0, 1, 0]),
                    segment("next-B", start: 70, end: 90, embedding: [0.8, 0.6, 0])
                ]
            )
        ]

        let linked = DiarizationWindowLinker.link(results)
        let idsByStart = Dictionary(uniqueKeysWithValues: linked.map { (Int($0.start), $0.speakerId) })

        #expect(idsByStart[160] == "S2")
        #expect(idsByStart[190] == "S1")
    }

    @Test("Sweep do gate de novo fixa 0,599 e 0,600")
    func sweepsNewClusterGate() {
        let below = linkSingleNextObservation(similarity: 0.599)
        let at = linkSingleNextObservation(similarity: 0.600)

        #expect(Set(below.map(\.speakerId)) == ["S1", "S2"])
        #expect(
            Set(at.map(\.speakerId)) == ["S1", DiarizedSegment.unassignedSpeakerId],
            "0,600 não cria identidade nova — e a fala continua visível como não-atribuída"
        )
        #expect(at.filter(\.isAssigned).allSatisfy { $0.speakerId == "S1" })
    }

    @Test("Sweep do matching fixa 0,779 e 0,780")
    func sweepsMatchGate() {
        let below = linkSingleNextObservation(similarity: 0.779)
        let at = linkSingleNextObservation(similarity: 0.780)

        #expect(below.filter(\.isAssigned).reduce(0) { $0 + $1.duration } == 20)
        #expect(at.filter(\.isAssigned).reduce(0) { $0 + $1.duration } == 40)
        #expect(at.allSatisfy { $0.speakerId == "S1" })
        // Abaixo do limiar a segunda observação não casa — e sobra como
        // sentinela, com a duração intacta.
        #expect(below.filter { !$0.isAssigned }.reduce(0) { $0 + $1.duration } == 20)
    }

    @Test("Sweep de fragmento duplicado fixa 0,879 e 0,880")
    func sweepsDuplicateGate() {
        let below = linkDuplicateObservation(similarity: 0.879)
        let at = linkDuplicateObservation(similarity: 0.880)

        #expect(below.filter(\.isAssigned).reduce(0) { $0 + $1.duration } == 40)
        #expect(at.filter(\.isAssigned).reduce(0) { $0 + $1.duration } == 60)
        #expect(at.allSatisfy { $0.speakerId == "S1" })
        #expect(below.filter { !$0.isAssigned }.reduce(0) { $0 + $1.duration } == 20)
    }

    @Test("Same-gender sintético na faixa 0,60–0,78 fica não atribuído")
    func sameGenderUncertaintyBandIsUnassigned() {
        let linked = linkSingleNextObservation(similarity: 0.70)

        // Similarity 0.70 is intentionally neither a cross-window match nor a new identity:
        // the uncertainty band avoids both a false merge and a false participant.
        #expect(linked.filter(\.isAssigned).map(\.speakerId) == ["S1"])
        // Mas a fala não desaparece: fica marcada como sem identidade.
        #expect(linked.filter { !$0.isAssigned }.count == 1)
    }

    // MARK: - MAIOR 1 — não-atribuído não pode virar atribuição errada

    @Test("Turn sobre fala não-atribuída NÃO rouba o vizinho")
    func unassignedSpeechDoesNotStealTheNeighbour() {
        let segments = [
            DiarizedSegment(speakerId: "S1", start: 0, end: 10, embedding: [1, 0]),
            DiarizedSegment(
                speakerId: DiarizedSegment.unassignedSpeakerId,
                start: 20,
                end: 30,
                embedding: [0.7, 0.7]
            )
        ]
        // O turn cai inteiro sobre a fala sem identidade.
        #expect(
            DiarizationTurnAttribution.dominantCluster(start: 21, end: 29, segments: segments) == nil,
            "sem identidade não se inventa uma — o turn mantém a atribuição anterior"
        )
        // Com evidência de verdade, atribui normalmente.
        #expect(
            DiarizationTurnAttribution.dominantCluster(start: 1, end: 9, segments: segments) == "S1"
        )
        // Sobreposição mista: quem cobre mais manda, e S1 cobre mais.
        #expect(
            DiarizationTurnAttribution.dominantCluster(start: 5, end: 24, segments: segments) == "S1"
        )
    }

    @Test("Fallback de proximidade tem distância máxima de 2s")
    func proximityFallbackHasAMaximumDistance() {
        let segments = [DiarizedSegment(speakerId: "S1", start: 0, end: 10, embedding: [1, 0])]

        #expect(
            DiarizationTurnAttribution.dominantCluster(start: 11, end: 13, segments: segments) == "S1",
            "1s de folga é desalinhamento de fronteira entre VADs"
        )
        #expect(
            DiarizationTurnAttribution.dominantCluster(start: 12, end: 14, segments: segments) == "S1",
            "2,0s é o limite inclusivo"
        )
        #expect(
            DiarizationTurnAttribution.dominantCluster(start: 12.1, end: 14, segments: segments) == nil,
            "sem teto, um turn a minutos de distância recebia o participante errado"
        )
        #expect(
            DiarizationTurnAttribution.dominantCluster(start: 600, end: 610, segments: segments) == nil
        )
    }

    @Test("Fallback não atribui quando o vizinho mais próximo é não-atribuído")
    func proximityFallbackIgnoresTheSentinel() {
        let segments = [
            DiarizedSegment(
                speakerId: DiarizedSegment.unassignedSpeakerId,
                start: 10,
                end: 12,
                embedding: [1, 0]
            ),
            DiarizedSegment(speakerId: "S1", start: 0, end: 5, embedding: [1, 0])
        ]
        #expect(
            DiarizationTurnAttribution.dominantCluster(start: 13, end: 14, segments: segments) == nil,
            "o mais próximo é fala sem identidade; S1 está longe demais"
        )
    }

    @Test("Sessão inteira não-atribuída não vira lista de falantes vazia")
    func fullyUnassignedSessionKeepsTheExistingRoster() {
        // Uma única observação curta: não cria global nenhum. Antes o linker
        // devolvia array vazio e o applyDiarization saía cedo; agora devolve o
        // sentinela, e sair cedo continua sendo a decisão certa — reconstruir a
        // lista de falantes apagaria o participante genérico que já existia.
        let linked = DiarizationWindowLinker.link([
            result(
                index: 0,
                start: 0,
                end: 180,
                segments: [segment("blip", start: 0, end: 0.5, embedding: [1, 0])]
            )
        ])
        #expect(linked.isEmpty == false)
        #expect(linked.contains(where: \.isAssigned) == false)
    }

    @Test("Agregados usam denominador RAW, não a soma do que sobrou")
    func statsUseRawDenominator() {
        let linked = DiarizationWindowLinker.linkDetailed([
            result(
                index: 0,
                start: 0,
                end: 180,
                segments: [
                    segment("dominant", start: 0, end: 100, embedding: [1, 0]),
                    segment("band", start: 110, end: 130, embedding: [0.7, 0.71414284])
                ]
            )
        ])

        #expect(linked.stats.rawDuration == 120)
        #expect(linked.stats.assignedDuration == 100)
        #expect(linked.stats.unassignedDuration == 20)
        #expect(linked.stats.droppedDuration == 0)
        #expect(abs(linked.stats.unassignedRate - (20.0 / 120.0)) < 0.0001)
        #expect(linked.stats.durationByCluster["S1"] == 100)
        #expect(linked.stats.windowCountByCluster["S1"] == 1)
        #expect(linked.stats.birthSimilarityByCluster["S1"] == -1)
        #expect(
            linked.stats.logSummary.contains("raw=120.00s"),
            "o log tem que trazer o denominador raw — sem ele a proxy não é interpretável"
        )
    }

    // MARK: - MAIOR 2 — midpoint por região

    @Test("Overlap misto: o que só um lado viu sobrevive inteiro")
    func mixedOverlapKeepsOneSidedSpeech() {
        // Overlap 120…180 (midpoint 150). Ambas veem 130…140; só a esquerda vê
        // 160…170. O corte por JANELA apagava 160…170 e a direita não repunha.
        let linked = DiarizationWindowLinker.link([
            result(
                index: 0,
                start: 0,
                end: 180,
                segments: [
                    segment("left-shared", start: 130, end: 140, embedding: [1, 0]),
                    segment("left-only", start: 160, end: 170, embedding: [1, 0])
                ]
            ),
            result(
                index: 1,
                start: 120,
                end: 300,
                segments: [segment("right-shared", start: 10, end: 20, embedding: [1, 0])]
            )
        ])

        let spans = linked.map { ($0.start, $0.end) }
        #expect(
            spans.contains(where: { $0.0 == 160 && $0.1 == 170 }),
            "fala vista por um lado só fica inteira com quem viu"
        )
        #expect(
            spans.contains(where: { $0.0 == 130 && $0.1 == 140 }),
            "a fala compartilhada continua aparecendo uma vez só"
        )
        #expect(linked.count == 2, "e não duplicada")
        #expect(DiarizationWindowLinker.unionDuration(linked.map { $0.start..<$0.end }) == 20)
    }

    @Test("Fala compartilhada no overlap não duplica")
    func sharedOverlapSpeechIsNotDuplicated() {
        let linked = DiarizationWindowLinker.link([
            result(
                index: 0,
                start: 0,
                end: 180,
                segments: [segment("left", start: 130, end: 175, embedding: [1, 0])]
            ),
            result(
                index: 1,
                start: 120,
                end: 300,
                segments: [segment("right", start: 10, end: 55, embedding: [1, 0])]
            )
        ])
        #expect(linked.count == 1)
        #expect(linked.first?.start == 130)
        #expect(linked.first?.end == 175)
    }

    @Test("Sub-região: a cauda unilateral de um segmento parcialmente compartilhado sobrevive")
    func partiallySharedSegmentKeepsItsOneSidedTail() {
        // Fixture do Codex: a esquerda vê [130,170]; a direita vê só [130,140].
        // Decidir pelo SEGMENTO inteiro mandava tudo ao midpoint e a cauda
        // [150,170] — que só a esquerda viu — sumia.
        let linked = DiarizationWindowLinker.link([
            result(
                index: 0,
                start: 0,
                end: 180,
                segments: [segment("left", start: 130, end: 170, embedding: [1, 0])]
            ),
            result(
                index: 1,
                start: 120,
                end: 300,
                segments: [segment("right", start: 10, end: 20, embedding: [1, 0])]
            )
        ])

        let union = DiarizationWindowLinker.unionDuration(linked.map { $0.start..<$0.end })
        #expect(union == 40, "os 40s de [130,170] têm que sobreviver inteiros")
        #expect(linked.map(\.start).min() == 130)
        #expect(linked.map(\.end).max() == 170)
        #expect(
            linked.allSatisfy { $0.speakerId == "S1" },
            "e continua sendo uma voz só, não duas"
        )
    }

    @Test("Sub-região não duplica o trecho que as duas janelas viram")
    func sharedSubRegionIsStillDeduplicated() {
        let linked = DiarizationWindowLinker.link([
            result(
                index: 0,
                start: 0,
                end: 180,
                segments: [segment("left", start: 130, end: 170, embedding: [1, 0])]
            ),
            result(
                index: 1,
                start: 120,
                end: 300,
                segments: [segment("right", start: 10, end: 50, embedding: [1, 0])]
            )
        ])
        // Ambas veem [130,170] inteiro: corte em 150, metade para cada uma, e o
        // merge costura de volta num segmento só.
        #expect(linked.count == 1)
        #expect(linked.first?.start == 130)
        #expect(linked.first?.end == 170)
    }

    // MARK: - MENOR — janela DETECTORA

    @Test("Fragmento de borda não vira w2 falso: conta a janela que detectou")
    func windowCountUsesTheDetectingWindow() {
        let linked = DiarizationWindowLinker.linkDetailed([
            result(
                index: 0,
                start: 0,
                end: 180,
                segments: [
                    segment("dominant", start: 0, end: 100, embedding: [1, 0]),
                    // Dentro do overlap [120,180], mas só a janela 0 detectou.
                    segment("edge", start: 130, end: 145, embedding: [0, 1])
                ]
            ),
            result(
                index: 1,
                start: 120,
                end: 300,
                segments: [segment("same-dominant", start: 80, end: 140, embedding: [1, 0])]
            )
        ])

        #expect(linked.stats.windowCountByCluster["S1"] == 2)
        #expect(
            linked.stats.windowCountByCluster["S2"] == 1,
            "o fragmento cruza os limites da janela 1 sem ela nunca o ter detectado"
        )
        #expect(linked.stats.durationByCluster["S2"] == 15)
    }

    // MARK: - Filtro de apresentação (produto)

    @Test("Cluster de 6s não vira participante, e a fala dele não some")
    func shortClusterIsDemotedButItsSpeechSurvives() {
        let linked = DiarizationWindowLinker.linkDetailed([
            result(
                index: 0,
                start: 0,
                end: 180,
                segments: [
                    segment("dominant", start: 0, end: 100, embedding: [1, 0]),
                    segment("ghost", start: 110, end: 116, embedding: [0, 1])
                ]
            )
        ])

        #expect(linked.stats.demotedClusters["S2"] == 6)
        #expect(
            linked.stats.durationByCluster.keys.sorted() == ["S1"],
            "6s não vira Participante N no card nem no export"
        )
        #expect(linked.stats.birthSimilarityByCluster["S2"] == nil)

        // A fala continua no transcript, como não-identificada.
        let ghost = linked.segments.filter { !$0.isAssigned }
        #expect(ghost.count == 1)
        #expect(ghost.first?.start == 110)
        #expect(ghost.first?.end == 116)
        #expect(linked.stats.unassignedDuration == 6)
        #expect(
            DiarizationWindowLinker.unionDuration(linked.segments.map { $0.start..<$0.end }) == 106,
            "nada desapareceu da linha do tempo"
        )
    }

    @Test("Cluster de 10s é preservado — a fronteira é inclusiva")
    func tenSecondClusterIsKept() {
        let linked = DiarizationWindowLinker.linkDetailed([
            result(
                index: 0,
                start: 0,
                end: 180,
                segments: [
                    segment("dominant", start: 0, end: 100, embedding: [1, 0]),
                    segment("minority", start: 110, end: 120, embedding: [0, 1])
                ]
            )
        ])
        #expect(linked.stats.demotedClusters.isEmpty)
        #expect(linked.stats.durationByCluster["S2"] == 10)
    }

    // MARK: - MAIOR 3+4 — matching por cardinalidade

    @Test("Cardinalidade vence a soma: 5 pares de 0,78+ ganham de 4 pares 1,0")
    func matchingPrefersCardinalityOverSum() {
        // Soma pura: obs i → cluster i, quatro arestas 1,0 (soma 4,00) e a
        // quinta voz fica sem par. Cardinalidade: cinco pares (soma 3,95).
        let similarities: [[Float?]] = [
            [1.00, nil, nil, nil, 0.80],
            [0.79, 1.00, nil, nil, nil],
            [nil, 0.79, 1.00, nil, nil],
            [nil, nil, 0.79, 1.00, nil],
            [nil, nil, nil, 0.78, nil]
        ]

        let assignment = DiarizationWindowLinker.optimalAssignment(similarities: similarities)
        #expect(assignment.count == 5, "nenhuma voz com aresta válida pode ficar sem atribuição")
        #expect(assignment == [0: 4, 1: 0, 2: 1, 3: 2, 4: 3])

        let sum = assignment.reduce(0.0) { $0 + Double(similarities[$1.key][$1.value] ?? 0) }
        #expect(sum < 4.0, "a soma é MENOR que a do matching de 4 pares — e ainda assim vence")
    }

    @Test("Desempate por soma quando a cardinalidade empata")
    func matchingBreaksTiesBySum() {
        let similarities: [[Float?]] = [
            [0.99, 0.80],
            [0.85, 0.90]
        ]
        #expect(DiarizationWindowLinker.optimalAssignment(similarities: similarities) == [0: 0, 1: 1])
    }

    @Test("Matching ignora arestas abaixo do limiar e aceita retângulos")
    func matchingRespectsThresholdAndRectangularShapes() {
        #expect(DiarizationWindowLinker.optimalAssignment(similarities: [[0.77, 0.5]]).isEmpty)
        // Mais observações que clusters (transpõe internamente).
        let crowded: [[Float?]] = [[0.90], [0.95], [0.80]]
        let assignment = DiarizationWindowLinker.optimalAssignment(similarities: crowded)
        #expect(assignment == [1: 0], "só um par possível, e é o melhor")
        // Mais clusters que observações.
        #expect(
            DiarizationWindowLinker.optimalAssignment(similarities: [[0.80, 0.95, 0.79]]) == [0: 1]
        )
    }

    // MARK: - Reconciliação final global-global

    @Test("Globais nascidos cedo e nunca reconciliados fundem no fim")
    func lateReconciliationMergesTwinGlobals() {
        // S1 nasce na janela 0. Na janela 1 chega uma voz que, contra o
        // centroide AINDA POBRE de S1, fica abaixo de 0,60 e vira S2. Cada um
        // recebe evidência longa numa janela SÓ SUA (nunca coocorrem), e os
        // centroides finais se encostam em ~0,91.
        let linked = DiarizationWindowLinker.linkDetailed([
            result(
                index: 0,
                start: 0,
                end: 180,
                segments: [segment("a", start: 0, end: 40, embedding: [1, 0])]
            ),
            result(
                index: 1,
                start: 400,
                end: 600,
                segments: [segment("b", start: 0, end: 40, embedding: [0.5, 0.8660254])]
            ),
            result(
                index: 2,
                start: 800,
                end: 1100,
                segments: [segment("c", start: 0, end: 250, embedding: [0.92718385, 0.37460659])]
            ),
            result(
                index: 3,
                start: 1200,
                end: 1700,
                segments: [segment("d", start: 0, end: 400, embedding: [0.74314483, 0.66913061])]
            )
        ])

        #expect(
            Set(linked.segments.filter(\.isAssigned).map(\.speakerId)).count == 1,
            "os dois fragmentos da mesma voz não podem atravessar a reunião como participantes distintos"
        )
        #expect(linked.stats.reconciledClusters["S2"] == "S1")
        #expect(linked.stats.durationByCluster.count == 1)
    }

    @Test("Reconciliação NÃO funde dois globais que coocorreram numa janela")
    func reconciliationRespectsCoOccurrence() {
        // Duas vozes parecidas (0,93 no fim) que o diarizador separou LOCALMENTE
        // na janela 2: a atribuição é 1:1, então dois globais ali são dois slots
        // locais distintos — duas pessoas. Fundir apagaria um participante real.
        let linked = DiarizationWindowLinker.linkDetailed([
            result(
                index: 0,
                start: 0,
                end: 180,
                segments: [segment("a", start: 0, end: 40, embedding: [1, 0])]
            ),
            result(
                index: 1,
                start: 400,
                end: 600,
                segments: [segment("b", start: 0, end: 40, embedding: [0.5, 0.8660254])]
            ),
            result(
                index: 2,
                start: 800,
                end: 1400,
                segments: [
                    segment("c", start: 0, end: 250, embedding: [0.92718385, 0.37460659]),
                    segment("d", start: 260, end: 660, embedding: [0.74314483, 0.66913061])
                ]
            )
        ])

        #expect(
            linked.stats.reconciledClusters.isEmpty,
            "coocorrência é prova de que são duas pessoas — nenhuma similaridade desfaz isso"
        )
        #expect(Set(linked.segments.filter(\.isAssigned).map(\.speakerId)) == ["S1", "S2"])
    }

    @Test("Reconciliação não funde vozes distintas")
    func lateReconciliationKeepsDistinctVoices() {
        let linked = DiarizationWindowLinker.linkDetailed([
            result(
                index: 0,
                start: 0,
                end: 180,
                segments: [
                    segment("a", start: 0, end: 40, embedding: [1, 0]),
                    segment("b", start: 60, end: 100, embedding: [0, 1])
                ]
            )
        ])
        #expect(linked.stats.reconciledClusters.isEmpty)
        #expect(Set(linked.segments.map(\.speakerId)) == ["S1", "S2"])
    }

    // MARK: - Semente fraca

    @Test("Semente fraca não prende a voz longa na faixa de incerteza")
    func weakSeedDoesNotHoldBackALongVoice() {
        // A planning de 12/10: a 3ª pessoa estreia com 7,5 s ruidosos e vira S3.
        // A fala longa dela dá 0,76 contra essa semente — abaixo de 0,78 (não
        // liga) e acima de 0,60 (não cria) — e fica sem dono a reunião inteira.
        // No fim S3 é rebaixado por ter menos de 10 s, e a pessoa some.
        let seed: [Float] = [0.4596, 0.4596, 0.76]
        let linked = DiarizationWindowLinker.linkDetailed([
            result(
                index: 0,
                start: 0,
                end: 180,
                segments: [
                    segment("a", start: 0, end: 60, embedding: [1, 0, 0]),
                    segment("b", start: 70, end: 130, embedding: [0, 1, 0])
                ]
            ),
            result(
                index: 1,
                start: 400,
                end: 580,
                segments: [
                    segment("a", start: 0, end: 50, embedding: [1, 0, 0]),
                    segment("b", start: 60, end: 100, embedding: [0, 1, 0]),
                    segment("seed", start: 110, end: 117.5, embedding: seed)
                ]
            ),
            result(
                index: 2,
                start: 800,
                end: 980,
                segments: [
                    segment("a", start: 0, end: 40, embedding: [1, 0, 0]),
                    segment("c", start: 50, end: 125, embedding: [0, 0, 1]),
                    segment("b", start: 130, end: 170, embedding: [0, 1, 0])
                ]
            ),
            result(
                index: 3,
                start: 1200,
                end: 1380,
                segments: [
                    segment("c", start: 0, end: 80, embedding: [0, 0, 1]),
                    segment("a", start: 90, end: 150, embedding: [1, 0, 0])
                ]
            )
        ])

        #expect(
            linked.stats.durationByCluster.count == 3,
            "a 3ª voz precisa virar participante: \(linked.stats.logSummary)"
        )
        let third = linked.segments.filter { $0.start == 850 || $0.start == 1200 }
        #expect(third.count == 2)
        #expect(third.allSatisfy { $0.isAssigned })
        #expect(Set(third.map(\.speakerId)).count == 1, "a voz longa é uma pessoa só")
        #expect(linked.stats.durationByCluster[third.first?.speakerId ?? ""] == 155)
        // A semente não é absorvida: os 7,5 s dela seguem sem dono.
        #expect(linked.stats.demotedClusters["S3"] == 7.5)
        #expect(linked.stats.unassignedDuration == 7.5)
        #expect(linked.stats.supersededSeeds == ["S4": ["S3"]])
        #expect(linked.stats.birthSimilarityByCluster["S4"] == 0, "nascimento segue < 0,60 sem a semente superada")
    }

    @Test("Nascimento ainda registra a semente fraca que não estava na faixa")
    func birthSimilarityKeepsAWeakSeedBelowTheBand() {
        // Só a semente superada (≥ 0,60) sai da conta. Uma semente fraca a 0,30
        // nunca bloqueou nada e continua sendo o vizinho mais próximo no log.
        let linked = DiarizationWindowLinker.linkDetailed([
            result(
                index: 0,
                start: 0,
                end: 180,
                segments: [
                    segment("blip", start: 0, end: 3, embedding: [1, 0]),
                    segment("voice", start: 10, end: 40, embedding: [0.3, 0.9539392])
                ]
            )
        ])

        #expect(linked.stats.birthSimilarityByCluster["S2"].map { abs($0 - 0.3) < 0.0001 } == true)
        #expect(linked.stats.supersededSeeds.isEmpty)
    }

    @Test("Semente vista nas duas janelas da sobreposição continua fraca")
    func seedSeenTwiceInTheOverlapStaysWeak() {
        // Os mesmos 7,5 s caem na sobreposição de 60 s e as duas janelas os
        // detectam. Somar as observações daria 15 s e a semente passaria por
        // participante estabelecido; a fala única dela continua sendo 7,5 s.
        let seed: [Float] = [0.4596, 0.4596, 0.76]
        let linked = DiarizationWindowLinker.linkDetailed([
            result(
                index: 0,
                start: 0,
                end: 180,
                segments: [
                    segment("a", start: 0, end: 60, embedding: [1, 0, 0]),
                    segment("b", start: 70, end: 110, embedding: [0, 1, 0]),
                    segment("seed", start: 150, end: 157.5, embedding: seed)
                ]
            ),
            result(
                index: 1,
                start: 120,
                end: 300,
                segments: [
                    segment("seed", start: 30, end: 37.5, embedding: seed),
                    segment("b", start: 100, end: 150, embedding: [0, 1, 0])
                ]
            ),
            result(
                index: 2,
                start: 400,
                end: 580,
                segments: [segment("c", start: 50, end: 125, embedding: [0, 0, 1])]
            ),
            result(
                index: 3,
                start: 800,
                end: 980,
                segments: [segment("c", start: 0, end: 80, embedding: [0, 0, 1])]
            )
        ])

        #expect(
            linked.stats.durationByCluster["S4"] == 155,
            "a voz longa vira participante: \(linked.stats.logSummary)"
        )
        #expect(linked.stats.supersededSeeds == ["S4": ["S3"]])
        #expect(linked.stats.demotedClusters["S3"] == 7.5)
        #expect(linked.stats.unassignedDuration == 7.5)
    }

    @Test("Voz longa na faixa de um participante estabelecido continua sem dono")
    func longVoiceInTheBandOfAnEstablishedSpeakerStaysUnassigned() {
        // A semente fraca não segura a faixa; um participante com 60 s, sim.
        // Duas vozes parecidas continuam sem fusão forçada nem participante falso.
        let linked = DiarizationWindowLinker.linkDetailed([
            result(
                index: 0,
                start: 0,
                end: 180,
                segments: [segment("a", start: 0, end: 60, embedding: [1, 0, 0])]
            ),
            result(
                index: 1,
                start: 400,
                end: 580,
                segments: [segment("x", start: 0, end: 75, embedding: [0.7, 0.71414284, 0])]
            )
        ])

        #expect(linked.stats.durationByCluster.keys.sorted() == ["S1"])
        #expect(linked.stats.unassignedDuration == 75)
        #expect(linked.stats.supersededSeeds.isEmpty)
    }

    @Test("Fala curta na faixa de uma semente fraca continua sem dono")
    func shortVoiceInTheBandOfAWeakSeedStaysUnassigned() {
        // Só uma observação que já seria participante sozinha (10 s) passa por
        // cima da semente. Fragmentos curtos não multiplicam sementes.
        let linked = DiarizationWindowLinker.linkDetailed([
            result(
                index: 0,
                start: 0,
                end: 180,
                segments: [
                    segment("a", start: 0, end: 60, embedding: [1, 0, 0]),
                    segment("seed", start: 70, end: 77.5, embedding: [0.4596, 0.4596, 0.76])
                ]
            ),
            result(
                index: 1,
                start: 400,
                end: 580,
                segments: [segment("c", start: 0, end: 6, embedding: [0, 0, 1])]
            )
        ])

        #expect(linked.stats.durationByCluster.keys.sorted() == ["S1"])
        #expect(linked.stats.demotedClusters["S2"] == 7.5)
        #expect(linked.stats.unassignedDuration == 13.5)
        #expect(linked.stats.supersededSeeds.isEmpty)
    }

    // MARK: - Religação final

    @Test("Fala sem dono religa ao centroide final do participante")
    func unassignedSpeechRelinksToTheFinalCentroid() {
        // A planning de 12/10, janela 27: 69 s davam 0,74 contra o centroide
        // que o participante tinha ali — faixa de incerteza, sem dono — e 0,86
        // contra o centroide final dele. Ninguém mais ocupava a janela.
        let linked = linkLateEvidence(laterEvidence: 30)

        #expect(linked.stats.durationByCluster == ["S1": 159], "\(linked.stats.logSummary)")
        #expect(linked.stats.relinkedClusters == ["S1": 69])
        #expect(linked.stats.unassignedDuration == 0)
        #expect(linked.segments.first { $0.start == 410 }?.speakerId == "S1")
    }

    @Test("Religação respeita a regra 1:1 da janela")
    func relinkKeepsOneToOnePerWindow() {
        // Com o participante já na janela, a mesma fala (0,86 no fim) precisa
        // da barra de duplicata, 0,88.
        let present = [segment("a", start: 0, end: 1, embedding: [1, 0])]
        let occupied = linkLateEvidence(laterEvidence: 30, alongside: present)
        #expect(occupied.stats.relinkedClusters.isEmpty)
        #expect(occupied.stats.unassignedDuration == 69)

        // Com mais fala dele depois, o centroide final chega a 0,95: duplicata.
        let duplicate = linkLateEvidence(laterEvidence: 120, alongside: present)
        #expect(duplicate.stats.relinkedClusters == ["S1": 69])

        // Duas falas sem dono disputam o participante livre: só a melhor (0,86)
        // o ocupa na barra de casamento. A outra dá 0,82 — sozinha religaria,
        // mas agora precisaria de 0,88.
        let rival = segment("y", start: 90, end: 110, embedding: [0.6819984, 0.7313537])
        let contested = linkLateEvidence(laterEvidence: 30, alongside: [rival])
        #expect(contested.stats.relinkedClusters == ["S1": 69])
        #expect(contested.segments.first { $0.start == 490 }?.isAssigned == false)
    }

    @Test("Fala que a janela vizinha leva não disputa a religação")
    func relinkIgnoresSpeechTheNeighbourOwns() {
        // Na sobreposição, a janela 1 fica com o que vem depois do meio (150 s):
        // "a" (0,90 no fim) não sobra na linha do tempo da janela 0. Religá-la
        // não mudaria segmento nenhum; ela não pode tirar de "b" (0,85), que
        // sobrou, o único participante livre. As duas são curtas demais para criar.
        let linked = DiarizationWindowLinker.linkDetailed([
            result(
                index: 0,
                start: 0,
                end: 180,
                segments: [
                    segment("b", start: 70, end: 71.5, embedding: Array(embedding(atCosine: 0.85).reversed())),
                    segment("a", start: 155, end: 156.5, embedding: Array(embedding(atCosine: 0.90).reversed()))
                ]
            ),
            result(
                index: 1,
                start: 120,
                end: 300,
                segments: [segment("c", start: 35, end: 36.5, embedding: [1, 0])]
            ),
            result(
                index: 2,
                start: 400,
                end: 580,
                segments: [segment("p", start: 0, end: 60, embedding: [0, 1])]
            )
        ])

        #expect(linked.stats.relinkedClusters == ["S1": 1.5], "\(linked.stats.logSummary)")
        #expect(linked.segments.first { $0.start == 70 }?.speakerId == "S1")
        #expect(linked.segments.first { $0.start == 155 }?.isAssigned == false)
    }

    @Test("Religação não leva fala a quem não seria apresentado")
    func relinkNeverPromotesADemotedSeed() {
        // A semente tem 12 s de trechos, mas a janela seguinte deu o mesmo
        // trecho a S1: depois do corte no meio da sobreposição, sobram 8 s dela
        // na linha do tempo, e ela é rebaixada. A fala sem dono dá 0,97 contra
        // ela; religar criaria um participante que ninguém estabeleceu.
        let seed: [Float] = [0.5, 0.8660254, 0]
        let linked = DiarizationWindowLinker.linkDetailed([
            result(
                index: 0,
                start: 0,
                end: 180,
                segments: [segment("a", start: 0, end: 60, embedding: [1, 0, 0])]
            ),
            result(
                index: 1,
                start: 400,
                end: 580,
                segments: [segment("x", start: 0, end: 20, embedding: [0.7, 0.71414284, 0])]
            ),
            result(
                index: 2,
                start: 800,
                end: 980,
                segments: [segment("seed", start: 142, end: 154, embedding: seed)]
            ),
            result(
                index: 3,
                start: 920,
                end: 1100,
                segments: [segment("a", start: 22, end: 34, embedding: [1, 0, 0])]
            )
        ])

        #expect(linked.stats.durationByCluster.keys.sorted() == ["S1"])
        #expect(linked.stats.demotedClusters["S2"] == 8)
        #expect(linked.stats.relinkedClusters.isEmpty)
        #expect(linked.stats.unassignedDuration == 28)
    }

    @Test("Sweep da religação fixa 0,779 e 0,780")
    func sweepsRelinkGate() {
        let below = linkBandSpeechBeforeItsVoice(similarity: 0.779)
        let at = linkBandSpeechBeforeItsVoice(similarity: 0.780)

        #expect(below.stats.relinkedClusters.isEmpty)
        #expect(below.stats.unassignedDuration == 20)
        #expect(at.stats.relinkedClusters == ["S2": 20])
        #expect(at.stats.unassignedDuration == 0)
    }

    @Test("Materializa o centroide global para persistência do MeetingSpeaker")
    func materializesGlobalCentroid() {
        let incoming = embedding(atCosine: 0.90)
        let linked = DiarizationWindowLinker.link([
            result(
                index: 0,
                start: 0,
                end: 180,
                segments: [segment("first", start: 0, end: 10, embedding: [1, 0])]
            ),
            result(
                index: 1,
                start: 120,
                end: 300,
                segments: [segment("next", start: 40, end: 60, embedding: incoming)]
            )
        ])

        let expected = normalized([
            10 + (incoming[0] * 20),
            incoming[1] * 20
        ])

        #expect(linked.count == 2)
        #expect(linked.allSatisfy { segment in
            let embedding = segment.embedding
            return embedding.count == expected.count
                && zip(embedding, expected).allSatisfy { abs($0 - $1) < 0.0001 }
        })
    }

    @Test("MeetingSpeaker antigo sem embedding continua decodificando")
    func decodesLegacyMeetingSpeaker() {
        let data = Data(#"{"id":"systemAudio","source":"systemAudio","name":"Participantes"}"#.utf8)
        let decoded = try? JSONDecoder().decode(MeetingSpeaker.self, from: data)

        #expect(decoded?.id == "systemAudio")
        #expect(decoded?.embedding == nil)
    }

    private func linkSingleNextObservation(similarity: Float) -> [DiarizedSegment] {
        DiarizationWindowLinker.link([
            result(
                index: 0,
                start: 0,
                end: 180,
                segments: [segment("first", start: 0, end: 20, embedding: [1, 0])]
            ),
            result(
                index: 1,
                start: 120,
                end: 300,
                segments: [segment("next", start: 40, end: 60, embedding: embedding(atCosine: similarity))]
            )
        ])
    }

    private func linkDuplicateObservation(similarity: Float) -> [DiarizedSegment] {
        DiarizationWindowLinker.link([
            result(
                index: 0,
                start: 0,
                end: 180,
                segments: [segment("first", start: 0, end: 20, embedding: [1, 0])]
            ),
            result(
                index: 1,
                start: 120,
                end: 300,
                segments: [
                    segment("primary", start: 40, end: 60, embedding: [1, 0]),
                    segment("duplicate", start: 70, end: 90, embedding: embedding(atCosine: similarity))
                ]
            )
        ])
    }

    /// S1 fala 60 s; na janela 1, 69 s a 0,74 do centroide dele ficam sem dono
    /// (faixa de incerteza); na janela 2, mais fala de S1 puxa o centroide
    /// final para perto deles: 0,86 com 30 s, 0,95 com 120 s.
    private func linkLateEvidence(
        laterEvidence: TimeInterval,
        alongside neighbours: [DiarizedSegment] = []
    ) -> DiarizationLinkResult {
        DiarizationWindowLinker.linkDetailed([
            result(
                index: 0,
                start: 0,
                end: 180,
                segments: [segment("a", start: 0, end: 60, embedding: [1, 0])]
            ),
            result(
                index: 1,
                start: 400,
                end: 580,
                segments: [segment("x", start: 10, end: 79, embedding: embedding(atCosine: 0.74))] + neighbours
            ),
            result(
                index: 2,
                start: 800,
                end: 980,
                segments: [segment("a", start: 0, end: laterEvidence, embedding: [0.8, 0.6])]
            )
        ])
    }

    /// A fala sem dono fica na faixa de S1 (≈0,63) antes de a voz dela existir.
    /// S2 nasce depois exatamente em `[0, 1]`: a similaridade final é `similarity`.
    private func linkBandSpeechBeforeItsVoice(similarity: Float) -> DiarizationLinkResult {
        DiarizationWindowLinker.linkDetailed([
            result(
                index: 0,
                start: 0,
                end: 180,
                segments: [
                    segment("q", start: 0, end: 60, embedding: [1, 0]),
                    segment("x", start: 70, end: 90, embedding: Array(embedding(atCosine: similarity).reversed()))
                ]
            ),
            result(
                index: 1,
                start: 400,
                end: 580,
                segments: [segment("p", start: 0, end: 60, embedding: [0, 1])]
            )
        ])
    }

    private func embedding(atCosine similarity: Float) -> [Float] {
        let value = Double(similarity)
        return [similarity, Float(sqrt(max(0, 1 - (value * value))))]
    }

    private func normalized(_ embedding: [Float]) -> [Float] {
        let magnitude = sqrt(embedding.reduce(0) { $0 + ($1 * $1) })
        return embedding.map { $0 / magnitude }
    }

    private func result(
        index: Int,
        start: TimeInterval,
        end: TimeInterval,
        segments: [DiarizedSegment]
    ) -> DiarizationWindowResult {
        DiarizationWindowResult(
            window: DiarizationWindow(index: index, start: start, end: end),
            segments: segments
        )
    }

    private func segment(
        _ speakerID: String,
        start: TimeInterval,
        end: TimeInterval,
        embedding: [Float]
    ) -> DiarizedSegment {
        DiarizedSegment(
            speakerId: speakerID,
            start: start,
            end: end,
            embedding: embedding
        )
    }
}
