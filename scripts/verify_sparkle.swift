#!/usr/bin/env swift
// Verify the generated feed and archive with only the app's public key, independently
// of Sparkle's signing process. No Keychain, extraction, app launch or network access.
import CryptoKit
import Foundation

struct VerificationError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

func require(_ condition: Bool, _ message: String) throws {
    if !condition { throw VerificationError(message) }
}

func verify(feed: URL, archive: URL, infoURL: URL, localTest: Bool) throws {
    let sparkleNamespace = "http://www.andymatuschak.org/xml-namespaces/sparkle"
    let infoData = try Data(contentsOf: infoURL)
    guard let info = try PropertyListSerialization.propertyList(from: infoData, format: nil) as? [String: Any],
          let encodedKey = info["SUPublicEDKey"] as? String,
          let keyBytes = Data(base64Encoded: encodedKey),
          let build = info["CFBundleVersion"] as? String,
          let version = info["CFBundleShortVersionString"] as? String else {
        throw VerificationError("Info.plist sem chave pública ou versão/build")
    }
    let key = try Curve25519.Signing.PublicKey(rawRepresentation: keyBytes)
    let signedFeed = try Data(contentsOf: feed)
    // Sparkle 2.10 appends this exact signature block. Refuse ambiguous/trailing data.
    let marker = Data("<!-- sparkle-signatures:\n".utf8)
    guard let markerRange = signedFeed.range(of: marker, options: .backwards),
          let trailer = String(data: signedFeed[markerRange.lowerBound...], encoding: .utf8) else {
        throw VerificationError("Appcast sem bloco de assinatura Sparkle")
    }
    let pattern = #"\A<!-- sparkle-signatures:\nedSignature: ([A-Za-z0-9+/=]+)\nlength: ([0-9]+)\n-->\n\z"#
    let regex = try NSRegularExpression(pattern: pattern)
    guard let match = regex.firstMatch(in: trailer, range: NSRange(trailer.startIndex..., in: trailer)),
          let signatureRange = Range(match.range(at: 1), in: trailer),
          let lengthRange = Range(match.range(at: 2), in: trailer),
          let signature = Data(base64Encoded: String(trailer[signatureRange])),
          let length = Int(trailer[lengthRange]) else {
        throw VerificationError("Bloco de assinatura Sparkle inválido")
    }
    let content = signedFeed[..<markerRange.lowerBound]
    try require(content.count == length, "Tamanho assinado do appcast incorreto")
    try require(key.isValidSignature(signature, for: content), "Assinatura do appcast inválida")

    let xml = try XMLDocument(data: Data(content), options: [.nodeLoadExternalEntitiesNever])
    let channels = xml.rootElement()?.elements(forName: "channel") ?? []
    try require(xml.rootElement()?.name == "rss" && channels.count == 1, "Estrutura do appcast inválida")
    let items = channels[0].elements(forName: "item")
    try require(items.count == 1, "Esperado um item de atualização")
    let item = items[0]
    func sparkleValue(_ name: String) -> String? {
        let nodes = item.children?.filter { $0.localName == name && $0.uri == sparkleNamespace } ?? []
        return nodes.count == 1 ? nodes[0].stringValue : nil
    }
    try require(sparkleValue("version") == build, "Build incorreto no appcast")
    try require(sparkleValue("shortVersionString") == version, "Versão incorreta no appcast")
    let enclosures = item.elements(forName: "enclosure")
    try require(enclosures.count == 1, "Esperado um pacote de atualização")
    let enclosure = enclosures[0]
    let prefix = localTest ? "http://localhost:8765/" : "https://voiz.dev/updates/"
    try require(enclosure.attribute(forName: "url")?.stringValue == prefix + archive.lastPathComponent,
                "URL de download incorreta")
    guard let archiveSignatureText = enclosure.attributes?.first(where: {
        $0.localName == "edSignature" && $0.uri == sparkleNamespace
    })?.stringValue, let archiveSignature = Data(base64Encoded: archiveSignatureText) else {
        throw VerificationError("Assinatura de atualização ausente ou inválida")
    }
    let archiveBytes = try Data(contentsOf: archive, options: .mappedIfSafe)
    try require(enclosure.attribute(forName: "length")?.stringValue == String(archiveBytes.count),
                "Tamanho do pacote incorreto")
    try require(key.isValidSignature(archiveSignature, for: archiveBytes), "Assinatura do pacote inválida")
}

do {
    var arguments = Array(CommandLine.arguments.dropFirst())
    let localTest = arguments.first == "--local-test"
    if localTest { arguments.removeFirst() }
    try require(arguments.count == 3,
                "Uso: swift scripts/verify_sparkle.swift [--local-test] APPCAST ZIP INFO_PLIST_DO_APP")
    try verify(feed: URL(fileURLWithPath: arguments[0]),
               archive: URL(fileURLWithPath: arguments[1]),
               infoURL: URL(fileURLWithPath: arguments[2]), localTest: localTest)
    print("Assinaturas Ed25519 do appcast/pacote e versão/build verificados com a chave pública do app (\(localTest ? "ensaio localhost" : "canal oficial")).")
} catch {
    fputs("Distribuição Sparkle bloqueada: \(error)\n", stderr)
    exit(1)
}
