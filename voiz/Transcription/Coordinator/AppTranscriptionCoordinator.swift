import Foundation

// O dono do coordenador dentro do app (T2.4a/T2.4b).
//
// A T2.3 deixou `TranscriptionCoordinator` **sem singleton e sem instância default** de propósito:
// ele é o dono dos motores, e um construtor de conveniência criaria um segundo dono — dois
// WhisperKit, dois `AsrManager`, e a regra de "um modelo pesado residente" valendo só sobre metade
// do app. A consequência disso é que alguém precisa segurar a instância única, e esse alguém não
// pode ser um view model: o ditado (`TranscriptionViewModel`, T2.4a) e a tradução
// (`TranslationViewModel`, T2.4b) são objetos independentes, criados pelo `ContentView`, e cada um
// criando o seu daria exatamente os dois donos que a T2.3 evitou.
//
// Este arquivo é esse lugar, e só isso: **um** coordenador, **um** `ParakeetTranscriptionService`
// e **um** `TranscriptionRuntimeStore` para o processo inteiro. Ele não conhece view model nenhum
// e não decide nada sobre transcrição — quem monta pedido, seleção e política é quem consome.
//
// `@MainActor` porque `TranscriptionCoordinator.make(...)` é `@MainActor` (o
// `TranscriptionRuntimeStore` é da UI) e porque os consumidores são view models da main actor: o
// acesso ao holder não precisa de hop, o trabalho pesado acontece dentro do ator do coordenador.
//
// Fora dos testes de propósito: montar este holder instancia os motores de verdade (WhisperKit +
// FluidAudio), que é o que `LiveTranscriptionCoordinator.swift` já evita levar para o alvo
// `voizTests`. O que os testes exercitam é o mapeamento de settings → pedido, que vive nos tipos
// puros.

/// A instância única do coordenador de transcrição do app.
///
/// Uso: `AppTranscriptionCoordinator.shared.coordinator` (e `.runtimeStore`, para quem quiser
/// mostrar a carga na tela).
///
/// ## O que a preguiça daqui protege — e o que não
///
/// A versão anterior deste doc prometia "preguiçoso de ponta a ponta: enquanto a tela que consome
/// o coordenador não é usada, não há motor novo nenhum na memória". Isso é falso no app que existe,
/// e a review da Quilha pegou: o `ContentView` cria o `TranslationViewModel` no boot, e o
/// `private let coordinator = AppTranscriptionCoordinator.shared.coordinator` dele é inicializador
/// de propriedade armazenada — então o coordenador e os dois motores nascem no boot, sempre.
///
/// O que é verdade: **motor não é peso**. `WhisperKitTranscriptionEngine` e
/// `ParakeetTranscriptionEngine` nascem vazios (o `AsrManager` do Parakeet e o `WhisperKit` só
/// existem depois de um `prepare`), e o `ParakeetTranscriptionService` daqui é preguiçoso por
/// dentro. Quem traz peso para a memória é o **aquecimento** — `warmUp` no `init` da tradução — e
/// só do modelo do rank 0.
@MainActor
final class AppTranscriptionCoordinator {

    static let shared = AppTranscriptionCoordinator()

    /// O serviço do Parakeet que o coordenador governa.
    ///
    /// É **deste** holder e de mais ninguém. Com a T2.5 isso deixou de ser aspiração: o
    /// `MeetingViewModel` era o último view model com um `ParakeetTranscriptionService` próprio, e
    /// não tem mais. O único runtime de transcrição vivo fora daqui é o WhisperKit small interno do
    /// `MeetingLivePreviewService` (prévia ao vivo), que é da Onda 4.
    let parakeetService = ParakeetTranscriptionService()

    /// O espelho da carga dos motores para a tela (gauge de download, "carregando", "pronto").
    ///
    /// Ninguém o observa ainda; a UI que o consome é a Onda 6. Existe desde já porque é a fábrica
    /// do coordenador que amarra os observadores dos motores a ele — ligar depois exigiria
    /// reconstruir os motores.
    let runtimeStore = TranscriptionRuntimeStore()

    private var storage: TranscriptionCoordinator?

    private init() {}

    /// O coordenador único, construído no primeiro acesso.
    var coordinator: TranscriptionCoordinator {
        if let storage { return storage }
        // `foreignOwners` continua VAZIO — e agora por um motivo melhor que "ainda não dá". A T2.5
        // avaliou ligar a ponte e decidiu que não: ver `LegacyWhisperWeightOwner`, abaixo.
        let created = TranscriptionCoordinator.make(
            parakeetService: parakeetService,
            runtimeStore: runtimeStore
        )
        storage = created
        return created
    }

    // Havia aqui um `unloadAll()` que **ninguém chamava** — `git grep` só achava a declaração
    // (MENOR da Quilha na T2.5). Foi removido em vez de mantido, e a escolha tem um motivo: com a
    // reunião migrada, este holder passou a ser o dono de todos os pesos de transcrição do processo,
    // e um gancho de liberação sem dono é pior que a ausência dele — o doc prometia "para pressão de
    // memória ou para o app fechar a última tela que transcreve" e nada disso existia.
    //
    // O que fica valendo, e é o estado de hoje: **nada libera os pesos até o app fechar**. Terminado
    // o pós-call de uma reunião com `large-v3-turbo`, 1,5 GB fica residente. É paridade com o legado
    // (o singleton do `TranscriptionService` também nunca soltava nada), então não é regressão desta
    // tarefa; é uma decisão que precisa de dono.
    //
    // Quem adotar o gancho — Onda 6 (um "descarregar modelos" nas Configurações, pressão de memória)
    // ou T7 — chama `TranscriptionCoordinator.unloadAll()`, que continua existindo, testado e com a
    // semântica certa (toma a vaga, então espera o trabalho em voo terminar em vez de puxar pesos
    // por baixo dele). Reintroduzir o atalho aqui é uma linha.
}

/// O `TranscriptionService.shared` legado visto como dono de pesos que não é motor do coordenador.
///
/// ## ESTE TIPO EXISTE E **NÃO** É INJETADO — e a T2.5 decidiu que continua assim.
///
/// Ele é a ponte que a T2.3 construiu (`TranscriptionForeignWeightOwner`) e que a review da Quilha
/// na T2.4b pediu para ligar, com um custo medido e correto: com `large-v3-turbo` configurado, dois
/// consumidores aqueciam 1,5 GB cada. A decisão do Maestro (DECISOES, 2026-08-10) foi adiar a
/// injeção para a T2.5, porque até lá a reunião transcrevia pelo `TranscriptionService.shared` e
/// liberar os pesos dele no meio de uma gravação seria pior que a duplicação.
///
/// A T2.5 chegou, o `MeetingViewModel` migrou — e a conclusão é **não injetar**, por três motivos
/// que só ficaram visíveis agora:
///
/// 1. **Não há mais o que liberar.** O `MeetingViewModel` era o **último** consumidor do
///    `TranscriptionService.shared` no app (`configure`, `ensureInitialized`, `transcribe`). Sem
///    ele, ninguém inicializa o serviço: como `shared` é um `static let` preguiçoso, o singleton
///    nem chega a ser construído, e um WhisperKit que nunca carrega não tem peso para soltar. A
///    duplicação de ~480 MB que a T2.3 aceitou como consequência **fechou sozinha**, que era o
///    resultado que a injeção perseguia.
/// 2. **Injetar não é grátis — custaria o aquecimento pesado de todo mundo.** O
///    `wouldEvictForeignWeights` do coordenador é conservador de propósito: com a lista de donos
///    externos **não vazia**, ele responde "sim, evictaria" para qualquer candidato `.heavy`, sem
///    perguntar a ninguém se há de fato algo residente. O `warmUp` então desiste (regra 4: nunca
///    evictar por cortesia). Ou seja: injetar um dono que nunca tem nada desligaria o
///    pré-aquecimento de `medium`, `large-v3-turbo` e Parakeet — no ditado e na reunião. Isso é
///    regressão de cadência (a primeira frase pós-boot pagaria download + carga dentro do pedido)
///    em troca de zero memória economizada.
/// 3. **A corrida que a Quilha apontou continua real, e some por não ser alcançável.**
///    `TranscriptionService.release()` não sobrevive a uma carga em voo (`initializeWhisper`
///    suspende em dois `await` e reatribui `whisperKit`/`isInitialized` ao voltar), e a correção
///    seria um contador de geração como o dos motores da T2.1/T2.2. Sem nenhum caminho que inicie
///    uma carga, não há carga em voo — consertar o serviço agora seria endurecer código que o T7.1
///    vai remover.
///
/// **O que precisa ser verdade para ligar**, se um dia algum caminho voltar a carregar pesos por
/// fora do coordenador: (a) o contador de geração no `initializeWhisper`, ou um `release()` que
/// recuse/aguarde carga em voo; e (b) `wouldEvictForeignWeights` perguntando ao dono se ele **tem**
/// algo pesado, em vez de assumir que sim — senão o item 2 volta como regressão silenciosa. O sinal
/// de "há reunião gravando", que era o bloqueio anterior, deixou de ser necessário: a reunião não
/// passa mais pelo serviço legado.
///
/// Fica no código, e não deletado, porque a remoção do caminho legado inteiro
/// (`configure(modelName:)`, este serviço, os switches de motor) é a T7.1, com dogfood humano antes.
///
/// **Só libera quando o que o serviço legado segura é pesado.** Quem responde "isto é pesado?" é o
/// catálogo, o mesmo que o coordenador consulta — duas leituras de peso no mesmo processo seria o
/// jeito mais silencioso de a regra falhar.
struct LegacyWhisperWeightOwner: TranscriptionForeignWeightOwner {
    nonisolated var ownerDescription: String { "TranscriptionService.shared (WhisperKit legado)" }

    /// O catálogo que decide o peso. O mesmo default do roteador do coordenador — se um dia forem
    /// catálogos diferentes, é aqui que a divergência tem que aparecer.
    var catalog: TranscriptionCatalog = .shipping

    func releaseHeavyWeights() async {
        await MainActor.run {
            let service = TranscriptionService.shared
            let model = TranscriptionModelID(service.configuredModelName)
            guard catalog.weight(of: model, in: .whisperKit) == .heavy else { return }
            service.release()
        }
    }
}
