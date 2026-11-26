import Domain
import Foundation
import GitHubAPI

/// Lädt alle erreichbaren Repositorys seitenweise (Konzept 4.1, Stufe 1).
public struct InventoryFetcher: Sendable {
    public static let pageSize = 100

    public static let query = """
    query Inventory($cursor: String, $pageSize: Int!) {
      viewer {
        login
        repositories(
          first: $pageSize, after: $cursor,
          affiliations: [OWNER, COLLABORATOR, ORGANIZATION_MEMBER],
          ownerAffiliations: [OWNER, COLLABORATOR, ORGANIZATION_MEMBER],
          orderBy: {field: PUSHED_AT, direction: DESC}
        ) {
          totalCount
          pageInfo { hasNextPage endCursor }
          nodes {
            id nameWithOwner url isPrivate isFork isArchived pushedAt updatedAt
            issues(states: OPEN) { totalCount }
            pullRequests(states: OPEN) { totalCount }
          }
        }
      }
      rateLimit { limit cost remaining resetAt }
    }
    """

    private let client: GraphQLClient

    public init(client: GraphQLClient) {
        self.client = client
    }

    public func fetchAll(now: @Sendable () -> Date = Date.init) async throws -> InventorySnapshot {
        var cursor: String?
        var repositories: [RepoMeta] = []
        var totalCost = 0
        var pageCount = 0
        var login = ""
        var rateLimit: RateLimitInfo?

        repeat {
            let operation = GraphQLOperation<InventoryResponse>(
                name: "Inventory",
                query: Self.query,
                variables: [
                    "cursor": cursor.map(GraphQLVariable.string) ?? .null,
                    "pageSize": .int(Self.pageSize),
                ]
            )
            let page = try await client.send(operation).data
            pageCount += 1
            login = page.viewer.login
            repositories += page.viewer.repositories.nodes.map(\.repoMeta)
            totalCost += page.rateLimit?.cost ?? 0
            rateLimit = page.rateLimit?.info
            let info = page.viewer.repositories.pageInfo
            cursor = info.hasNextPage ? info.endCursor : nil
        } while cursor != nil && !Task.isCancelled

        try Task.checkCancellation()

        return InventorySnapshot(
            viewerLogin: login,
            repositories: repositories,
            fetchedAt: now(),
            totalCost: totalCost,
            pageCount: pageCount,
            rateLimit: rateLimit
        )
    }
}

// MARK: - Antwort-Typen

public struct InventoryResponse: Decodable, Sendable {
    public let viewer: Viewer
    public let rateLimit: RateLimit?

    public struct Viewer: Decodable, Sendable {
        public let login: String
        public let repositories: Connection
    }

    public struct Connection: Decodable, Sendable {
        public let totalCount: Int
        public let pageInfo: PageInfo
        public let nodes: [Node]
    }

    public struct PageInfo: Decodable, Sendable {
        public let hasNextPage: Bool
        public let endCursor: String?
    }

    public struct Count: Decodable, Sendable {
        public let totalCount: Int
    }

    public struct Node: Decodable, Sendable {
        public let id: String
        public let nameWithOwner: String
        public let url: URL
        public let isPrivate: Bool
        public let isFork: Bool
        public let isArchived: Bool
        public let pushedAt: Date?
        public let updatedAt: Date
        public let issues: Count
        public let pullRequests: Count

        var repoMeta: RepoMeta {
            RepoMeta(
                id: id,
                nameWithOwner: nameWithOwner,
                url: url,
                isPrivate: isPrivate,
                isFork: isFork,
                isArchived: isArchived,
                pushedAt: pushedAt,
                updatedAt: updatedAt,
                openIssueCount: issues.totalCount,
                openPullRequestCount: pullRequests.totalCount
            )
        }
    }

    public struct RateLimit: Decodable, Sendable {
        public let limit: Int
        public let cost: Int
        public let remaining: Int
        public let resetAt: Date

        var info: RateLimitInfo {
            RateLimitInfo(limit: limit, remaining: remaining, resetAt: resetAt, cost: cost)
        }
    }
}
