import Foundation

/// Stammdaten eines Repositorys aus der Bestandsabfrage (Konzept 4.1, Stufe 1).
public struct RepoMeta: Codable, Hashable, Sendable, Identifiable {
    /// GraphQL-Node-ID; Schlüssel für die gebündelten Detail-Abfragen über `nodes(ids:)`.
    public let id: String
    public let nameWithOwner: String
    public let url: URL
    public let isPrivate: Bool
    public let isFork: Bool
    public let isArchived: Bool
    public let pushedAt: Date?
    public let updatedAt: Date
    public let openIssueCount: Int
    public let openPullRequestCount: Int

    public init(
        id: String,
        nameWithOwner: String,
        url: URL,
        isPrivate: Bool,
        isFork: Bool,
        isArchived: Bool,
        pushedAt: Date?,
        updatedAt: Date,
        openIssueCount: Int,
        openPullRequestCount: Int
    ) {
        self.id = id
        self.nameWithOwner = nameWithOwner
        self.url = url
        self.isPrivate = isPrivate
        self.isFork = isFork
        self.isArchived = isArchived
        self.pushedAt = pushedAt
        self.updatedAt = updatedAt
        self.openIssueCount = openIssueCount
        self.openPullRequestCount = openPullRequestCount
    }

    public var owner: Substring { nameWithOwner.split(separator: "/").first ?? "" }
    public var name: Substring { nameWithOwner.split(separator: "/").last ?? "" }
}
