import Foundation

/// Provider text is staged in memory. Only an explicit apply takes a snapshot for storage;
/// typing never creates a queue of partially entered credentials.
nonisolated struct SettingsCredentialEditBuffer: Sendable {
    nonisolated struct Edit: Sendable {
        let field: SettingsCredentialField
        let value: String
        let revision: UUID
    }

    private(set) var values: [String: String] = [:]
    private(set) var revisions: [String: UUID] = [:]

    mutating func stage(_ field: SettingsCredentialField, value: String) {
        values[field.rawValue] = value
        revisions[field.rawValue] = UUID()
    }

    var pendingEdits: [Edit] {
        SettingsCredentialField.allCases.compactMap { field in
            guard let value = values[field.rawValue], let revision = revisions[field.rawValue] else { return nil }
            return Edit(field: field, value: value, revision: revision)
        }
    }

    func isCurrent(_ edit: Edit) -> Bool { revisions[edit.field.rawValue] == edit.revision }

    /// Failed writes leave their draft available for explicit retry. An older success
    /// cannot erase text entered after the user clicked Apply.
    @discardableResult
    mutating func acknowledge(_ edit: Edit) -> Bool {
        guard isCurrent(edit) else { return false }
        values.removeValue(forKey: edit.field.rawValue)
        return true
    }
}
