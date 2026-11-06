import Foundation
import Testing

@Suite("Conta Sync — nomes das bibliotecas arquivadas")
struct SyncArchiveNamesTests {
    private let locale = Locale(identifier: "pt-BR")
    private let day = Date(timeIntervalSince1970: 1_791_000_000)

    @Test("Datas diferentes viram nomes diferentes, sem identificador")
    func distinctDays() {
        let first = UUID(), second = UUID()
        let names = SyncArchiveNames.names(for: [(first, day), (second, day.addingTimeInterval(3 * 86_400))], locale: locale)
        #expect(names[first] != names[second])
        #expect(names.values.allSatisfy { !$0.contains(first.uuidString.prefix(8)) && !$0.contains("(") })
    }

    @Test("Arquivos do mesmo dia recebem ordinal")
    func sameDay() {
        let first = UUID(), second = UUID()
        let names = SyncArchiveNames.names(for: [(first, day), (second, day.addingTimeInterval(60))], locale: locale)
        #expect(names[first]?.hasSuffix("(1)") == true)
        #expect(names[second]?.hasSuffix("(2)") == true)
        #expect(names[first]?.dropLast(3) == names[second]?.dropLast(3))
    }

    @Test("Sem data, usa a posição na lista")
    func missingDate() {
        let first = UUID(), second = UUID()
        let archives: [(id: UUID, created: Date?)] = [(first, nil), (second, nil)]
        let names = SyncArchiveNames.names(for: archives, locale: locale)
        #expect(names[first] != names[second])
        #expect(names[first]?.hasSuffix("1") == true)
        #expect(names[second]?.hasSuffix("2") == true)
    }
}
