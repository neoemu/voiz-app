import Foundation

/// O instalador local nunca consulta o canal público. A distribuição habilita explicitamente
/// as atualizações, com HTTPS e a chave pública usada para verificar os pacotes.
struct AppUpdateConfiguration: Equatable {
    let feedURL: URL
    let publicKey: String

    init?(info: [String: Any]) {
        guard (info["VoizUpdatesEnabled"] as? String) == "YES",
              let feed = info["SUFeedURL"] as? String,
              let components = URLComponents(string: feed),
              components.scheme == "https",
              let host = components.host, !host.isEmpty,
              components.user == nil, components.password == nil, components.fragment == nil,
              let url = components.url,
              let key = info["SUPublicEDKey"] as? String,
              let bytes = Data(base64Encoded: key), bytes.count == 32
        else { return nil }
        feedURL = url
        publicKey = key
    }
}
