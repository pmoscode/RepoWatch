import Domain
import Foundation
import GitHubAPI
import ModuleKit

public struct IssueLabel: Codable, Sendable, Hashable {
    public let name: String
    /// Hex ohne `#`, wie von GitHub geliefert.
    public let color: String
}

public struct IssueSummary: Codable, Sendable, Hashable, Identifiable {
    public var id: Int { number }
    public let number: Int
    public let title: String
    public let url: URL
    public let createdAt: Date
    public let updatedAt: Date
    public let author: String?
    public let commentCount: Int
    public let labels: [IssueLabel]
}

public struct IssuesPayload: ModulePayload {
    /// Alle offenen Issues (ohne PRs; über GraphQL zählt `issues` nur echte Issues, Konzept 4.1).
    public let totalCount: Int
    /// Die zuletzt geänderten, höchstens `IssuesModule.pageSize`.
    public let items: [IssueSummary]
    public let hasMore: Bool
    /// Cursor für das Nachladen in der Detailansicht.
    public let endCursor: String?
}

/// Offene Issues pro Repo (Konzept 1, Bereich „Issues“).
public struct IssuesModule: InsightModule {
    public static let id = ModuleID("issues")
    public static let pageSize = 20

    public let metadata = ModuleMetadata(title: String(localized: "Issues"), systemImage: "smallcircle.filled.circle", defaultOrder: 10)

    public init() {}

    static let issueFields = """
    totalCount
    pageInfo { hasNextPage endCursor }
    nodes {
      number title url createdAt updatedAt
      author { login }
      comments { totalCount }
      labels(first: 5) { nodes { name color } }
    }
    """

    public var fragment: GraphQLFragment {
        GraphQLFragment("""
        m_issues_open: issues(states: OPEN, first: \(Self.pageSize), orderBy: {field: UPDATED_AT, direction: DESC}) {
          \(Self.issueFields.replacingOccurrences(of: "\n", with: "\n  "))
        }
        """)
    }

    struct Connection: Decodable {
        struct PageInfo: Decodable {
            let hasNextPage: Bool
            let endCursor: String?
        }
        struct Node: Decodable {
            struct Login: Decodable { let login: String }
            struct Count: Decodable { let totalCount: Int }
            struct Labels: Decodable { let nodes: [IssueLabel] }
            let number: Int
            let title: String
            let url: URL
            let createdAt: Date
            let updatedAt: Date
            let author: Login?
            let comments: Count
            let labels: Labels
        }
        let totalCount: Int
        let pageInfo: PageInfo
        let nodes: [Node]

        var items: [IssueSummary] {
            nodes.map {
                IssueSummary(
                    number: $0.number, title: $0.title, url: $0.url, createdAt: $0.createdAt, updatedAt: $0.updatedAt,
                    author: $0.author?.login, commentCount: $0.comments.totalCount, labels: $0.labels.nodes
                )
            }
        }
    }

    private struct Node: Decodable {
        let m_issues_open: Connection
    }

    public func decode(_ node: RepositoryNode, context: ModuleContext) throws -> IssuesPayload {
        let connection = try node.decode(Node.self).m_issues_open
        return IssuesPayload(
            totalCount: connection.totalCount,
            items: connection.items,
            hasMore: connection.pageInfo.hasNextPage,
            endCursor: connection.pageInfo.endCursor
        )
    }

    public func summarize(_ payload: IssuesPayload, context: ModuleContext) -> ModuleSummary {
        ModuleSummary(counts: ["open": payload.totalCount])
    }

    public func changes(from old: IssuesPayload?, to new: IssuesPayload, repository: RepoMeta) -> [Change] {
        guard let old else { return [] }
        return ItemDiff.changes(
            old: old.items.map(\.diffItem), new: new.items.map(\.diffItem), newHasMore: new.hasMore,
            module: Self.id, repository: repository
        )
    }
}

extension IssueSummary {
    var diffItem: ItemDiff.Item { ItemDiff.Item(number: number, title: title, url: url, updatedAt: updatedAt) }
}

// MARK: - Nachladen

public struct IssuePage: Sendable {
    public let items: [IssueSummary]
    public let hasMore: Bool
    public let endCursor: String?
}

extension IssuesModule {
    /// Weitere offene Issues eines Repos für die Detailansicht (Plan Phase 3, „Nachladen“).
    public static func fetchPage(
        client: GraphQLClient,
        repositoryID: String,
        after cursor: String?,
        pageSize: Int = 50
    ) async throws -> IssuePage {
        struct Response: Decodable, Sendable {
            struct Repository: Decodable, Sendable { let issues: Connection }
            let node: Repository?
        }
        let query = """
        query IssuePage($id: ID!, $after: String, $first: Int!) {
          node(id: $id) {
            ... on Repository {
              issues(states: OPEN, first: $first, after: $after, orderBy: {field: UPDATED_AT, direction: DESC}) {
                \(issueFields.replacingOccurrences(of: "\n", with: "\n        "))
              }
            }
          }
        }
        """
        let operation = GraphQLOperation<Response>(
            name: "IssuePage",
            query: query,
            variables: ["id": .string(repositoryID), "after": cursor.map(GraphQLVariable.string) ?? .null, "first": .int(pageSize)]
        )
        guard let issues = try await client.send(operation).data.node?.issues else {
            throw GitHubAPIError.decoding("Repository \(repositoryID) nicht gefunden")
        }
        return IssuePage(items: issues.items, hasMore: issues.pageInfo.hasNextPage, endCursor: issues.pageInfo.endCursor)
    }
}

extension IssuesModule.Connection: Sendable {}
extension IssuesModule.Connection.PageInfo: Sendable {}
extension IssuesModule.Connection.Node: Sendable {}
extension IssuesModule.Connection.Node.Login: Sendable {}
extension IssuesModule.Connection.Node.Count: Sendable {}
extension IssuesModule.Connection.Node.Labels: Sendable {}
