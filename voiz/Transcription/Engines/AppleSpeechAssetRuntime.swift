import Foundation

// A implementação de produção do `AppleSpeechRuntime`, sobre o `SpeechAnalyzer`/`AssetInventory`.
//
// Este arquivo depende **só de Foundation** — e é de propósito, pela mesma lição que a review do
// Farol deixou na T2.2: a semântica testada tem de ser a da ponte de produção, não a de um
// caminho paralelo. Toda a **decisão** do ciclo de vida do asset (a ordem reservar → ler status →
// instalar → reverificar, o que conta como sucesso, o que vira qual erro) mora aqui e é testada
// com dublê no lugar do framework. O que sobra fora dos testes é `AppleSpeechAnalyzerCalls`, que
// só encaminha chamada para o `Speech`.
//
// As regras abaixo vêm da sonda da T0.2 (DECISOES, 2026-08-07, Garoa). Elas não são preferências
// de estilo: cada uma corrige um comportamento medido do `AssetInventory` que, ignorado, faz o
// app baixar de novo o que já tem ou concluir que um locale instalado não existe.

/// Status do asset de um locale, no vocabulário do app.
///
/// Espelha `AssetInventory.Status` sem importar `Speech`, para este arquivo (e os testes)
/// continuarem puros.
nonisolated enum AppleSpeechAssetStatus: String, Sendable, Equatable, Hashable, CaseIterable {
    /// O locale/módulo não existe nesta máquina.
    case unsupported
    /// Suportado, mas **não** pronto para uso offline. Atenção: sem reserva, este é também o
    /// status de um asset que já está no disco (armadilha 1 da T0.2).
    case supported
    case downloading
    /// Pronto para uso offline — só reportado com o locale **reservado**.
    case installed
}

/// As chamadas do `Speech` de que o runtime precisa, sem `Speech`, sem `AVFAudio` e sem decisão.
///
/// Toda a assimetria do framework está descrita nos comentários de cada membro, porque é o que a
/// implementação de produção tem de reproduzir literalmente.
nonisolated protocol AppleSpeechCalls: Sendable {
    /// `SpeechTranscriber.isAvailable` — o transcritor existe nesta build do SO.
    var isAvailable: Bool { get async }

    /// `SpeechTranscriber.supportedLocale(equivalentTo:) != nil`.
    ///
    /// **Não reserva**: a T0.2 verificou que as leituras (`installedLocales`, init do módulo,
    /// `status`, formatos) deixam `reservedLocales` intacto.
    func isSupported(_ locale: AppleSpeechLocale) async -> Bool

    /// `AssetInventory.reserve(locale:)`.
    ///
    /// Devolve `true` quando criou a reserva e `false` quando o locale **já estava** reservado —
    /// os dois são sucesso (armadilha 2 da T0.2). Só o `throw` é erro; o caso real é o pool
    /// (`maximumReservedLocales == 5`) cheio.
    @discardableResult
    func reserve(_ locale: AppleSpeechLocale) async throws -> Bool

    /// `AssetInventory.maximumReservedLocales`.
    ///
    /// Lido **só** quando a reserva é recusada, para a mensagem de erro dizer o tamanho do pool em
    /// vez de "recusada". Não entra no caminho feliz.
    var maximumReservedLocales: Int { get async }

    /// `AssetInventory.status(forModules:)` para o transcritor do locale.
    ///
    /// Só faz sentido depois da reserva: sem ela, `.supported` não distingue "falta baixar" de
    /// "já está no disco" (armadilha 1 da T0.2).
    func status(_ locale: AppleSpeechLocale) async -> AppleSpeechAssetStatus

    /// `AssetInventory.assetInstallationRequest(supporting:)` seguido de `downloadAndInstall()`.
    ///
    /// Devolve `false` quando a request veio `nil` (nada a instalar). **Reserva implicitamente**
    /// (armadilha 4 da T0.2), então não serve como consulta barata "tem algo para baixar?" — quem
    /// chama aqui já decidiu instalar.
    @discardableResult
    func installAsset(_ locale: AppleSpeechLocale) async throws -> Bool

    /// Constrói e aquece o analyzer do locale, deixando-o residente.
    func activateAnalyzer(_ locale: AppleSpeechLocale) async throws

    /// O locale do analyzer residente agora; `nil` = nenhum.
    var activeLocale: AppleSpeechLocale? { get async }

    /// Roda um lote no analyzer residente.
    func run(
        samples: [Float],
        sampleRate: Double,
        locale: AppleSpeechLocale,
        context: TranscriptionContext
    ) async throws -> AppleSpeechRuntimeOutput

    /// Solta o analyzer residente e a retenção dos modelos do sistema.
    ///
    /// **Nunca** chama `AssetInventory.release(reservedLocale:)` — ver `AppleSpeechAssetRuntime.release()`.
    func deactivateAnalyzer() async
}

/// Falhas que a camada de chamadas reporta sem precisar do vocabulário de outro motor.
nonisolated enum AppleSpeechCallFailure: Error, Sendable, Equatable {
    /// A reserva foi recusada — na prática, o pool de `maximumReservedLocales` está cheio.
    case reservationRefused(String)
    /// O transcritor não oferece nenhum formato de áudio compatível com o pipeline do app.
    case noCompatibleAudioFormat
    /// Pediram para transcrever sem analyzer ativo.
    case analyzerNotActive
    /// A sequência de resultados do transcritor não terminou dentro do prazo do lote.
    ///
    /// Existe porque a coleta acontece **com a vaga única do motor na mão**: uma sequência que não
    /// termina prenderia o motor inteiro para sempre, inclusive o `unload` (que toma a vaga de
    /// forma não-cancelável). É a mesma consequência do vazamento de vaga que reprovou a rodada 3
    /// da T2.1, por outra porta.
    case collectionTimedOut(TimeInterval)
}

/// A coleta dos resultados de um lote, com prazo.
///
/// Mora neste arquivo — e não na camada de chamadas — porque é **decisão**: quanto esperar e o que
/// o estouro significa. A camada de chamadas só entrega a `Task` que lê a sequência do transcritor.
///
/// A razão de existir um prazo: esta espera acontece **com a vaga única do motor na mão**. Se a
/// sequência de resultados não terminar depois do `finalize`, o `await` não volta e o motor inteiro
/// fica preso — inclusive o `unload`, que toma a vaga de forma não-cancelável. É a mesma
/// consequência do vazamento de vaga que reprovou a rodada 3 da T2.1, por outra porta.
nonisolated enum AppleSpeechBatchCollection {

    /// Prazo proporcional ao áudio do lote.
    ///
    /// O múltiplo é folgado de propósito: a fumaça da T3.3 mediu RTFx entre 60x e 130x, então 4x
    /// tempo real é ~250 vezes o normal — só dispara se a sequência de fato não fechar, nunca por
    /// uma máquina lenta. O piso de 10 s protege lotes curtos, onde o proporcional seria pequeno
    /// demais para significar alguma coisa.
    static func deadline(forAudioSeconds seconds: TimeInterval) -> TimeInterval {
        max(10, seconds * 4)
    }

    /// Espera o coletor até `timeout`. Estourou: cancela o coletor e reporta `collectionTimedOut`.
    ///
    /// O coletor é uma `Task` **não estruturada** (precisa ser: ela começa antes de o analyzer
    /// arrancar), então não herda cancelamento — daí o `cancel()` explícito nos dois caminhos, o do
    /// prazo e o do chamador cancelado.
    static func collect(
        _ collector: Task<[AppleSpeechTranscriptSegment], any Error>,
        timeout: TimeInterval
    ) async throws -> [AppleSpeechTranscriptSegment] {
        try await withTaskCancellationHandler {
            try await withThrowingTaskGroup(of: [AppleSpeechTranscriptSegment]?.self) { group in
                group.addTask { try await collector.value }
                group.addTask {
                    // `try?`: no caminho feliz o coletor ganha e este sono é cancelado, o que não é
                    // erro — e o `nil` dele nunca chega a ser lido, porque quem chega primeiro ao
                    // `group.next()` é o coletor.
                    try? await Task.sleep(for: .seconds(timeout))
                    return nil
                }

                let first = try await group.next()
                group.cancelAll()
                guard let segments = first ?? nil else {
                    collector.cancel()
                    throw AppleSpeechCallFailure.collectionTimedOut(timeout)
                }
                return segments
            }
        } onCancel: {
            collector.cancel()
        }
    }
}

/// O `AppleSpeechRuntime` de produção.
///
/// A sequência de `load` é a **ordem** que a T0.2 provou necessária, e ela é o valor deste tipo:
///
/// 1. o transcritor existe nesta build do SO e fala o locale;
/// 2. **reserva antes de ler o status** — sem reserva, `.supported` não distingue "falta baixar"
///    de "já está no disco", e o app baixaria de novo o que já tem;
/// 3. `reserve` devolvendo `false` é sucesso ("já estava reservado"), não falha;
/// 4. só instala quando o status pede, porque `assetInstallationRequest` reserva implicitamente e
///    não pode ser usada como consulta;
/// 5. depois de instalar, **relê** o status: a instalação só vale se chegou a `.installed`;
/// 6. nada é cacheado entre sessões — a instalação de asset é revogável, então cada `load` remede
///    tudo do zero. Dentro de uma sessão quem evita a remedição é o caminho rápido do motor, e ele
///    só sobrevive enquanto o analyzer continua residente.
nonisolated struct AppleSpeechAssetRuntime: AppleSpeechRuntime {
    private let calls: any AppleSpeechCalls

    init(calls: any AppleSpeechCalls) {
        self.calls = calls
    }

    func load(model: TranscriptionModelID) async throws {
        let locale = try Self.locale(for: model)
        try Self.checkCancellation()

        guard await calls.isAvailable else {
            throw AppleSpeechRuntimeError.localeUnsupported("SpeechTranscriber indisponível nesta build do sistema")
        }
        guard await calls.isSupported(locale) else {
            throw AppleSpeechRuntimeError.localeUnsupported(locale.identifier)
        }
        try Self.checkCancellation()

        // Passo 2 e 3: reservar antes de interpretar o status; `false` é sucesso.
        //
        // Quando o pool está cheio, a saída que NÃO tomamos é liberar a reserva de outro locale
        // para abrir vaga (DECISOES, T3.3 (c)): a T0.2 mediu que `release(reservedLocale:)` derruba
        // o `status` daquele locale de `.installed` para `.supported` — o app estaria quebrando o
        // idioma do vizinho (possivelmente o de outra sessão viva, ou o do preview da T4.2) para
        // atender este pedido, e "recuperar-se" assim é pior que falhar. O erro é recuperável: o
        // coordenador cai para o WhisperKit, e quem decide liberar um idioma é o usuário.
        do {
            _ = try await calls.reserve(locale)
        } catch {
            if let failure = Self.cancellation(from: error) { throw failure }
            throw AppleSpeechRuntimeError.reservationPoolFull(
                "reserva de \(locale.identifier) recusada: o pool do AssetInventory "
                + "(máximo \(await calls.maximumReservedLocales) locales) não tem vaga — "
                + "\(Self.describe(error))"
            )
        }
        try Self.checkCancellation()

        switch await calls.status(locale) {
        case .installed:
            // Já pronto para uso offline. Nada a baixar — e, crucialmente, nenhuma
            // `assetInstallationRequest` a chamar só para descobrir isso.
            break
        case .unsupported:
            throw AppleSpeechRuntimeError.localeUnsupported(locale.identifier)
        case .supported, .downloading:
            // Passo 4: aqui a decisão de instalar já está tomada.
            do {
                _ = try await calls.installAsset(locale)
            } catch {
                if let failure = Self.cancellation(from: error) { throw failure }
                throw AppleSpeechRuntimeError.assetUnavailable(
                    "instalação do asset de \(locale.identifier) falhou: \(Self.describe(error))"
                )
            }
            try Self.checkCancellation()
            // Passo 5: a instalação só vale se o status confirmar. Uma request `nil` ("nada a
            // instalar") com status ainda fora de `installed` é exatamente o caso em que confiar
            // no retorno da chamada deixaria o motor anunciar um locale que não funciona.
            let confirmed = await calls.status(locale)
            guard confirmed == .installed else {
                throw AppleSpeechRuntimeError.assetUnavailable(
                    "asset de \(locale.identifier) ficou em \(confirmed.rawValue) após instalar"
                )
            }
        }

        try Self.checkCancellation()
        do {
            try await calls.activateAnalyzer(locale)
        } catch {
            throw Self.failure(from: error)
        }
    }

    func transcribe(
        samples: [Float],
        sampleRate: Double,
        model: TranscriptionModelID,
        context: TranscriptionContext = TranscriptionContext()
    ) async throws -> AppleSpeechRuntimeOutput {
        let locale = try Self.locale(for: model)

        // O runtime EXIGE o analyzer já ativo — o item 3 do contrato ("transcribe não
        // auto-prepara") tem de valer em TODAS as camadas, não só na do motor. Sem esta guarda,
        // uma violação de residência viraria reserva de locale e download de asset em silêncio,
        // fora dos livros do coordenador.
        guard await calls.activeLocale == locale else {
            throw AppleSpeechRuntimeError.assetUnavailable("analyzer de \(locale.identifier) não está ativo")
        }

        do {
            return try await calls.run(samples: samples, sampleRate: sampleRate, locale: locale, context: context)
        } catch {
            throw Self.failure(from: error)
        }
    }

    /// Solta o analyzer — e **só** o analyzer.
    ///
    /// DECISÃO (T3.3): `unload` **não** libera a reserva do locale. A T0.2 mediu que
    /// `AssetInventory.release(reservedLocale:)` derruba o `status` de `.installed` para
    /// `.supported` mesmo com o asset intacto no disco: quem libera a reserva perde a capacidade
    /// de distinguir "instalado" de "falta baixar" e faz o próximo `prepare` parecer um download
    /// pendente. O custo de manter a reserva é uma vaga num pool de 5.
    ///
    /// **Desde 29/08/2026 o app oferece 7 idiomas, e o pool tem 5 vagas.** Quem experimentar mais
    /// de cinco recebe `reservationPoolFull` no sexto e o coordenador cai para o WhisperKit
    /// naquele idioma — degradação, não quebra. Continua sem liberar reserva de vizinho para
    /// abrir vaga, pelo motivo acima: seria trocar um idioma que funciona por outro.
    ///
    /// O que `unload` promete continua valendo: a memória do analyzer e a retenção dos modelos do
    /// sistema são liberadas de verdade, que é o recurso caro que a regra "um modelo pesado
    /// residente" da T2.3 disputa.
    func release() async {
        await calls.deactivateAnalyzer()
    }

    // MARK: - Apoio

    private static func locale(for model: TranscriptionModelID) throws -> AppleSpeechLocale {
        guard let locale = AppleSpeechLocale(model: model) else {
            throw AppleSpeechRuntimeError.unsupportedModel(model)
        }
        return locale
    }

    private static func checkCancellation() throws {
        if Task.isCancelled { throw AppleSpeechRuntimeError.cancelled }
    }

    /// O erro é (ou aconteceu dentro de) um cancelamento?
    ///
    /// Mesma lição do CRITICO do Farol na T2.2: cancelamento vem **antes** do ramo genérico. Um
    /// download abortado não é asset quebrado, e classificá-lo como tal faria o coordenador
    /// refazer noutro motor um trabalho que alguém acabou de mandar parar — e ainda latcharia o
    /// modelo no cache negativo.
    private static func cancellation(from error: any Error) -> AppleSpeechRuntimeError? {
        if error is CancellationError || Task.isCancelled { return .cancelled }
        if let runtime = error as? AppleSpeechRuntimeError, runtime == .cancelled { return .cancelled }
        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled { return .cancelled }
        if nsError.domain == NSCocoaErrorDomain && nsError.code == NSUserCancelledError { return .cancelled }
        return nil
    }

    /// Classifica o erro cru que veio da camada de chamadas.
    static func failure(from error: any Error) -> AppleSpeechRuntimeError {
        if let cancelled = cancellation(from: error) { return cancelled }
        if let runtime = error as? AppleSpeechRuntimeError { return runtime }
        if let call = error as? AppleSpeechCallFailure {
            switch call {
            case .reservationRefused(let description):
                return .reservationPoolFull("reserva recusada: \(description)")
            case .noCompatibleAudioFormat:
                return .audioFormatUnsupported("o transcritor não oferece formato compatível com 16 kHz mono")
            case .analyzerNotActive:
                return .assetUnavailable("analyzer não está ativo")
            case .collectionTimedOut(let seconds):
                // `runtimeFailure` (→ `engineInternal`, que permite fallback): o lote é bom, quem
                // não respondeu foi este motor. O coordenador tenta o próximo candidato.
                return .runtimeFailure(
                    "o transcritor não fechou os resultados em \(Int(seconds))s"
                )
            }
        }
        return .runtimeFailure(describe(error))
    }

    /// Descrição técnica de um erro, para log. Nunca carrega texto transcrito.
    private static func describe(_ error: any Error) -> String {
        error.localizedDescription
    }
}
