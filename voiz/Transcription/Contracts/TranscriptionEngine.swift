import Foundation

/// O que todo motor de transcrição sabe fazer, independentemente de rodar em lote ou ao vivo.
///
/// `Sendable` porque o coordenador da Onda 2 guarda motores fora da main thread e os usa a
/// partir de tarefas concorrentes.
nonisolated protocol TranscriptionEngine: Sendable {
    /// As capacidades declaradas deste motor. É o mesmo descritor que está no catálogo — o
    /// roteador decide por ele, então motor e descritor discordarem é bug do motor.
    var descriptor: TranscriptionEngineDescriptor { get }

    /// Deixa o motor pronto para transcrever com `model`: baixa o que faltar, carrega os pesos.
    ///
    /// Idempotente — chamar duas vezes com o mesmo modelo não recarrega nada. Trocar o modelo
    /// é chamar de novo com outro id; é o que substitui o `configure(modelName:)` mutável de hoje.
    func prepare(model: TranscriptionModelID) async throws

    /// Libera os pesos residentes. O coordenador chama isto para manter a regra de **um**
    /// modelo pesado carregado por vez.
    func unload() async
}

/// Motor que recebe um bloco de áudio fechado e devolve o texto inteiro.
///
/// É o caminho do ditado, dos trechos de tradução e dos lotes do transcript oficial da reunião.
nonisolated protocol BatchTranscriptionEngine: TranscriptionEngine {
    /// Transcreve `request` usando o modelo de `candidate`.
    ///
    /// O candidato vem inteiro (e não só o id do modelo) porque o resultado carrega a
    /// proveniência: sem o `rank` e a `origin` que o roteador decidiu, o motor não teria como
    /// dizer se foi primeira escolha ou fallback. `TranscriptionProvenance(candidate:useCase:)`
    /// monta isso em uma linha.
    ///
    /// Lança `TranscriptionEngineFailure` quando o motivo é conhecido — é o `allowsFallback`
    /// dele que diz ao coordenador se vale tentar o próximo candidato do plano.
    func transcribe(
        _ request: TranscriptionRequest,
        candidate: TranscriptionRoutingCandidate
    ) async throws -> TranscriptionEngineResult
}

/// Motor que transcreve enquanto o áudio chega.
///
/// Só o preview da reunião precisa disso. A sessão é um objeto separado do motor porque um
/// motor pode ter várias sessões vivas (preview de uma reunião enquanto outra grava) e porque
/// o ciclo de vida dela — `append` … `finish` — é bem mais curto que o do motor.
nonisolated protocol StreamingTranscriptionEngine: TranscriptionEngine {
    func startStream(
        _ request: TranscriptionStreamRequest,
        candidate: TranscriptionRoutingCandidate
    ) async throws -> any TranscriptionStream
}

/// Uma sessão de streaming viva.
nonisolated protocol TranscriptionStream: Sendable {
    /// Eventos em ordem. Termina quando `finish()`/`cancel()` são chamados ou quando o motor
    /// falha — nesse caso o stream termina lançando `TranscriptionEngineFailure`.
    var events: AsyncThrowingStream<TranscriptionStreamEvent, any Error> { get }

    /// De onde vem o texto desta sessão. Fixa na abertura: uma sessão nunca troca de motor no
    /// meio — trocar é encerrar esta e abrir outra, que é o que o fallback do preview faz.
    var provenance: TranscriptionProvenance { get }

    /// Entrega mais áudio. A taxa tem que ser a que foi declarada em `TranscriptionStreamRequest`.
    func append(_ audio: TranscriptionAudio) async throws

    /// Fecha a entrada e deixa o motor emitir o que ainda estiver pendente antes de terminar
    /// o stream de eventos.
    func finish() async

    /// Encerra agora, descartando o que estiver pendente. Não emite mais nada.
    func cancel() async
}
