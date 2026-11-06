import Foundation
import Security

/// Token e destino do Notion. Keychain only — nunca UserDefaults, nunca plaintext em disco.
///
/// O posicionamento é BYO: o usuário cola o Internal Integration Token. Nada disso sai do
/// Mac além das chamadas que ele mesmo dispara no export.
struct NotionCredentialsStore: Sendable {
    static let shared = NotionCredentialsStore(service: AppEnvironment.current.keychainService(suffix: "notion"))

    var service: String

    enum Account: String, Sendable {
        case token
        case destination
    }

    func token() -> String {
        load(.token)
    }

    func destination() -> String {
        load(.destination)
    }

    var hasToken: Bool {
        !token().isEmpty
    }

    var hasDestination: Bool {
        !destination().isEmpty
    }

    func setToken(_ raw: String) {
        save(raw, account: .token)
    }

    func setDestination(_ raw: String) {
        save(raw, account: .destination)
    }

    func deleteAll() {
        delete(.token)
        delete(.destination)
    }

    func delete(_ account: Account) {
        SecItemDelete(baseQuery(account, dataProtection: true) as CFDictionary)
        SecItemDelete(baseQuery(account, dataProtection: false) as CFDictionary)
    }

    // MARK: - Keychain

    private func load(_ account: Account) -> String {
        if let value = read(account, dataProtection: true) { return value }
        return read(account, dataProtection: false) ?? ""
    }

    @discardableResult
    private func save(_ raw: String, account: Account) -> Bool {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            delete(account)
            return true
        }
        guard let data = trimmed.data(using: .utf8) else { return false }

        if write(data, account: account, dataProtection: true) { return true }
        // Testes (e alguns hosts sem entitlement) rejeitam data-protection;
        // o app sandboxed usa o primeiro caminho.
        return write(data, account: account, dataProtection: false)
    }

    private func write(_ data: Data, account: Account, dataProtection: Bool) -> Bool {
        var query = baseQuery(account, dataProtection: dataProtection)
        let update: [String: Any] = [kSecValueData as String: data]
        let updated = SecItemUpdate(query as CFDictionary, update as CFDictionary)
        if updated == errSecSuccess { return true }
        guard updated == errSecItemNotFound else { return false }
        query[kSecValueData as String] = data
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        return SecItemAdd(query as CFDictionary, nil) == errSecSuccess
    }

    private func read(_ account: Account, dataProtection: Bool) -> String? {
        var query: [String: Any] = baseQuery(account, dataProtection: dataProtection)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func baseQuery(_ account: Account, dataProtection: Bool) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account.rawValue
        ]
        if dataProtection {
            query[kSecUseDataProtectionKeychain as String] = true
        }
        return query
    }
}

/// Uma exportação que criou a página mas não subiu tudo, esperando ser avisada.
///
/// Persistir é o que garante que NENHUMA configuração deixa o parcial
/// silencioso. O aviso imediato depende de canal — o overlay do notch é
/// opt-in e vem desligado, e uma notificação do sistema depende de permissão
/// que o app pode não ter. O registro não depende de nada: fica no disco e a
/// tela da reunião o mostra na próxima abertura.
///
/// E o lugar importa: quem exporta de novo faz isso na tela da reunião, que é
/// exatamente onde o aviso aparece. O usuário não consegue re-exportar sem ver
/// que já existe uma página pela metade — que era o ponto.
struct NotionPartialExport: Codable, Equatable, Sendable {
    var pageURL: URL
    var appendedBlocks: Int
    var totalBlocks: Int
}

/// O slot de uma sessão. Guarda QUEM escreveu por último, e não só o quê.
///
/// Sem isso o slot é last-write-wins e a escrita atrasada vence: uma
/// exportação cancelada pode terminar DEPOIS de uma exportação nova da mesma
/// reunião e sobrescrever o link novo pelo velho — ou pior, gravar de novo
/// depois de a exportação nova ter concluído inteira e limpado, ressuscitando
/// o aviso de uma página que já não é a última verdade.
///
/// `partial == nil` é o slot LIMPO, e ele continua existindo de propósito: é
/// o que barra a escrita atrasada de ressuscitar o aviso.
struct NotionPartialSlot: Codable, Equatable, Sendable {
    /// A ORDEM da execução do app, não a identidade dela.
    ///
    /// Um UUID distingue execuções mas não as ordena, e ordenar é o que o
    /// problema exige: se a execução NOVA escreve primeiro, uma Task
    /// sobrevivente da execução VELHA ainda pode chegar depois. Sem ordem, a
    /// comparação não tem como recusá-la — e ela apaga o link novo.
    ///
    /// Com um contador que só cresce, a comparação vira lexicográfica:
    /// execução maior sempre vence, e dentro da mesma execução vale a geração.
    var runSequence: Int
    /// A geração que escreveu por último, inclusive quando escreveu uma limpeza.
    var generation: Int
    var partial: NotionPartialExport?
}

/// Registro local dos parciais pendentes de aviso, por sessão.
struct NotionPartialExportStore: Sendable {
    static let runSequenceKey = "com.rmb.voiz.notion.runSequence"
    /// Avaliado UMA vez por processo, porque `shared` é um `static let`.
    static let shared = NotionPartialExportStore(runSequence: nextRunSequence())

    var suiteName: String?
    var key = "com.rmb.voiz.notion.partialExports"
    /// Ver `NotionPartialSlot.runSequence`. Injetável para o teste poder
    /// encenar duas execuções.
    var runSequence: Int = 1

    /// Lê e incrementa o contador de execução, em disco.
    ///
    /// Persistente de propósito: um contador em memória reiniciaria em 1 a
    /// cada launch e voltaria a empatar com a execução anterior.
    static func nextRunSequence(in defaults: UserDefaults = .standard) -> Int {
        let next = defaults.integer(forKey: runSequenceKey) + 1
        defaults.set(next, forKey: runSequenceKey)
        return next
    }

    private var defaults: UserDefaults {
        suiteName.flatMap(UserDefaults.init(suiteName:)) ?? .standard
    }

    func pending(for sessionID: UUID) -> NotionPartialExport? {
        all()[sessionID.uuidString]?.partial
    }

    /// Grava o parcial se quem escreve ainda for a escrita mais recente.
    ///
    /// A EXISTÊNCIA do registro continua não dependendo de canal de UI — é o
    /// que salvou o aviso no cancelamento. O que passou a ter dono é a
    /// ESCRITA no slot: uma exportação atrasada não sobrescreve o resultado de
    /// uma mais nova da mesma reunião, nem ressuscita um aviso já limpo.
    @discardableResult
    func record(
        _ partial: NotionPartialExport,
        for sessionID: UUID,
        generation: Int
    ) -> Bool {
        write(partial, for: sessionID, generation: generation)
    }

    /// Chamado quando o usuário reconhece o aviso, ou quando uma exportação
    /// posterior conclui inteira — aí o parcial deixou de ser a última verdade.
    ///
    /// O slot NÃO é removido: fica com `partial == nil`, para uma escrita
    /// atrasada não ressuscitar o que acabou de ser limpo.
    @discardableResult
    func clear(for sessionID: UUID, generation: Int) -> Bool {
        write(nil, for: sessionID, generation: generation)
    }

    func all() -> [String: NotionPartialSlot] {
        guard let data = defaults.data(forKey: key),
              let decoded = try? JSONDecoder().decode([String: NotionPartialSlot].self, from: data)
        else { return [:] }
        return decoded
    }

    /// `false` quando a escrita foi recusada por ser mais velha que a atual.
    private func write(_ partial: NotionPartialExport?, for sessionID: UUID, generation: Int) -> Bool {
        var current = all()
        // Comparação lexicográfica `(execução, geração)`: a execução decide
        // primeiro, e só dentro dela a geração desempata. É isto que recusa a
        // Task sobrevivente de uma execução anterior, mesmo que a geração dela
        // seja altíssima.
        if let existing = current[sessionID.uuidString],
           (existing.runSequence, existing.generation) > (runSequence, generation) {
            return false
        }
        current[sessionID.uuidString] = NotionPartialSlot(
            runSequence: runSequence,
            generation: generation,
            partial: partial
        )
        guard let data = try? JSONEncoder().encode(current) else { return false }
        defaults.set(data, forKey: key)
        return true
    }
}
