import Foundation

/// Stand des GitHub-Kontingents nach einer Abfrage.
public struct RateLimitInfo: Codable, Hashable, Sendable {
    public let limit: Int
    public let remaining: Int
    public let resetAt: Date
    /// Kosten der letzten Abfrage (nur GraphQL).
    public let cost: Int?

    public init(limit: Int, remaining: Int, resetAt: Date, cost: Int?) {
        self.limit = limit
        self.remaining = remaining
        self.resetAt = resetAt
        self.cost = cost
    }
}

/// Ergebnis eines vollständigen Bestand-Durchlaufs (alle Seiten).
public struct InventorySnapshot: Codable, Hashable, Sendable {
    public let viewerLogin: String
    public let repositories: [RepoMeta]
    public let fetchedAt: Date
    /// Summe der GraphQL-Kosten über alle Seiten.
    public let totalCost: Int
    public let pageCount: Int
    public let rateLimit: RateLimitInfo?

    public init(
        viewerLogin: String,
        repositories: [RepoMeta],
        fetchedAt: Date,
        totalCost: Int,
        pageCount: Int,
        rateLimit: RateLimitInfo?
    ) {
        self.viewerLogin = viewerLogin
        self.repositories = repositories
        self.fetchedAt = fetchedAt
        self.totalCost = totalCost
        self.pageCount = pageCount
        self.rateLimit = rateLimit
    }

    public var totalOpenIssues: Int { repositories.reduce(0) { $0 + $1.openIssueCount } }
    public var totalOpenPullRequests: Int { repositories.reduce(0) { $0 + $1.openPullRequestCount } }
}
