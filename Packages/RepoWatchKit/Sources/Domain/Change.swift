import Foundation

/// Eine erkannte Änderung zwischen zwei Sync-Durchläufen (Konzept 9.3).
/// Grundlage für „neu seit dem letzten Blick“ und später für Benachrichtigungen.
public struct Change: Codable, Sendable, Hashable {
    public enum Kind: Codable, Sendable, Hashable {
        case repositoryAdded
        case repositoryRemoved
        case pushed
        case itemOpened
        case itemClosed
        case itemUpdated
        /// Modulspezifisch, z. B. `workflowFailed`, `workflowRecovered` (Konzept 8.3).
        case custom(String)
    }

    public let kind: Kind
    public let repositoryID: String
    public let repositoryName: String
    public let moduleID: ModuleID?
    /// Kennung des Eintrags im Modul, z. B. Issue-Nummer.
    public let itemID: String?
    public let title: String?
    public let url: URL?

    public init(
        kind: Kind,
        repositoryID: String,
        repositoryName: String,
        moduleID: ModuleID? = nil,
        itemID: String? = nil,
        title: String? = nil,
        url: URL? = nil
    ) {
        self.kind = kind
        self.repositoryID = repositoryID
        self.repositoryName = repositoryName
        self.moduleID = moduleID
        self.itemID = itemID
        self.title = title
        self.url = url
    }
}

public struct ChangeSet: Codable, Sendable, Equatable {
    public let detectedAt: Date
    public let changes: [Change]

    public init(detectedAt: Date, changes: [Change]) {
        self.detectedAt = detectedAt
        self.changes = changes
    }

    public var isEmpty: Bool { changes.isEmpty }
}
