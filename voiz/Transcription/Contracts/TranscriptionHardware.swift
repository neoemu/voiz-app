import Foundation

/// O Mac em que o app está rodando, reduzido ao que decide motor.
///
/// É um valor simples de propósito: o roteador precisa ser testável com um Intel de 8 GB sem
/// que exista um Intel na mesa. Quem constrói o perfil real é o coordenador (Onda 2), via
/// `detected()`.
nonisolated struct TranscriptionHardwareProfile: Sendable, Equatable, Hashable {
    nonisolated enum Architecture: String, Sendable, Hashable, Codable, CaseIterable {
        case appleSilicon
        case intel
    }

    var architecture: Architecture
    /// Neural Engine disponível. Na prática acompanha o Apple Silicon, mas fica explícito
    /// porque é a capacidade que os modelos CoreML pesados realmente exigem.
    var hasNeuralEngine: Bool
    var physicalMemoryBytes: UInt64

    init(architecture: Architecture, hasNeuralEngine: Bool, physicalMemoryBytes: UInt64) {
        self.architecture = architecture
        self.hasNeuralEngine = hasNeuralEngine
        self.physicalMemoryBytes = physicalMemoryBytes
    }

    /// O Mac atual. A arquitetura sai de `#if arch(...)` (o binário é o que ele é — Rosetta
    /// não muda o que este processo consegue rodar) e a memória, do `ProcessInfo`.
    ///
    /// Não é chamada por nada em `Contracts/`: o roteador nunca consulta a máquina sozinho,
    /// recebe o perfil pronto. Está aqui para não haver duas detecções divergentes no app.
    static func detected(processInfo: ProcessInfo = .processInfo) -> TranscriptionHardwareProfile {
        #if arch(arm64)
        let architecture = Architecture.appleSilicon
        #else
        let architecture = Architecture.intel
        #endif
        return TranscriptionHardwareProfile(
            architecture: architecture,
            hasNeuralEngine: architecture == .appleSilicon,
            physicalMemoryBytes: processInfo.physicalMemory
        )
    }
}

/// O mínimo que um motor (ou um modelo) exige da máquina.
///
/// Modelado como requisito × perfil, e não como uma lista de Macs suportados, porque o teste
/// que importa — "num Intel sobra só o WhisperKit" — precisa ser uma comparação, não um
/// catálogo de exceções.
nonisolated struct TranscriptionHardwareRequirement: Sendable, Equatable, Hashable {
    var requiresAppleSilicon: Bool
    var requiresNeuralEngine: Bool
    var minimumMemoryBytes: UInt64

    init(
        requiresAppleSilicon: Bool = false,
        requiresNeuralEngine: Bool = false,
        minimumMemoryBytes: UInt64 = 0
    ) {
        self.requiresAppleSilicon = requiresAppleSilicon
        self.requiresNeuralEngine = requiresNeuralEngine
        self.minimumMemoryBytes = minimumMemoryBytes
    }

    /// Roda em qualquer Mac que o app suporta.
    static let none = TranscriptionHardwareRequirement()

    /// Modelos CoreML pesados (Parakeet, e o TAGARELA a partir da Onda 5): Neural Engine e
    /// memória para manter os pesos residentes.
    static let appleSiliconNeuralEngine = TranscriptionHardwareRequirement(
        requiresAppleSilicon: true,
        requiresNeuralEngine: true,
        minimumMemoryBytes: 8 * 1024 * 1024 * 1024
    )

    func isSatisfied(by profile: TranscriptionHardwareProfile) -> Bool {
        if requiresAppleSilicon && profile.architecture != .appleSilicon { return false }
        if requiresNeuralEngine && !profile.hasNeuralEngine { return false }
        return profile.physicalMemoryBytes >= minimumMemoryBytes
    }
}
