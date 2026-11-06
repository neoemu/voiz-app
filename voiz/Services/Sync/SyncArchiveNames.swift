import Foundation

/// Names archives by folder date in the interface language; IDs mean nothing to people.
/// Archives from the same day get an ordinal so every entry stays distinguishable.
nonisolated enum SyncArchiveNames {
    static func names(for archives: [(id: UUID, created: Date?)], locale: Locale) -> [UUID: String] {
        let dates = archives.map { $0.created?.formatted(Date.FormatStyle(date: .abbreviated, time: .omitted).locale(locale)) }
        let totals = dates.compactMap { $0 }.reduce(into: [String: Int]()) { $0[$1, default: 0] += 1 }
        var seen: [String: Int] = [:]
        var result: [UUID: String] = [:]
        for (index, archive) in archives.enumerated() {
            guard let date = dates[index] else {
                result[archive.id] = String(localized: "Arquivada \(index + 1)")
                continue
            }
            if totals[date, default: 0] > 1 {
                seen[date, default: 0] += 1
                result[archive.id] = String(localized: "Arquivada de \(date) (\(seen[date, default: 1]))")
            } else {
                result[archive.id] = String(localized: "Arquivada de \(date)")
            }
        }
        return result
    }
}
