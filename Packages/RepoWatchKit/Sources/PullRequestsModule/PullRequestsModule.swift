import Domain
import Foundation
import ModuleKit

public struct PullRequestSummary: Codable, Sendable, Hashable, Identifiable {
    public var id: Int { number }
    public let number: Int
    public let title: String
    public let url: URL
    public let isDraft: Bool
    public let createdAt: Date
    public let updatedAt: Date
    public let branch: String
    public let authorLogin: String?
    /// Ergebnis der Regelkette (Konzept 6).
    public let authorKind: AuthorKind
    /// Status der Checks am letzten Commit; `nil` = keine Checks.
    public let ci: CIState?
}

public struct PullRequestsPayload: ModulePayload {
    public let totalCount: Int
    public let items: [PullRequestSummary]
    public let hasMore: Bool

    public func count(_ category: AuthorKind.Category) -> Int {
        items.filter { $0.authorKind.category == category }.count
    }
}

/// Offene PRs mit Autor-Art und CI-Status (Konzept 1, 6 und E7).
public struct PullRequestsModule: InsightModule {
    public static let id = ModuleID("prs")
    public static let pageSize = 30

    public let metadata = ModuleMetadata(title: String(localized: "Pull Requests"), systemImage: "arrow.triangle.pull", defaultOrder: 20)
    private let classifier: AuthorClassifier

    public init(rules: AuthorRules = .default) {
        classifier = .standard(rules)
    }

    public var fragment: GraphQLFragment {
        GraphQLFragment("""
        m_prs_open: pullRequests(states: OPEN, first: \(Self.pageSize), orderBy: {field: UPDATED_AT, direction: DESC}) {
          totalCount
          pageInfo { hasNextPage }
          nodes {
            number title url isDraft createdAt updatedAt headRefName
            author { __typename login }
            commits(last: 1) { nodes { commit { statusCheckRollup { state } } } }
          }
        }
        """)
    }

    private struct Node: Decodable {
        struct Connection: Decodable {
            struct PageInfo: Decodable { let hasNextPage: Bool }
            struct PullRequest: Decodable {
                struct Author: Decodable {
                    let __typename: String?
                    let login: String
                }
                struct Commits: Decodable {
                    struct Item: Decodable {
                        struct Commit: Decodable {
                            struct Rollup: Decodable { let state: String }
                            let statusCheckRollup: Rollup?
                        }
                        let commit: Commit
                    }
                    let nodes: [Item]
                }
                let number: Int
                let title: String
                let url: URL
                let isDraft: Bool
                let createdAt: Date
                let updatedAt: Date
                let headRefName: String
                let author: Author?
                let commits: Commits
            }
            let totalCount: Int
            let pageInfo: PageInfo
            let nodes: [PullRequest]
        }
        let m_prs_open: Connection
    }

    public func decode(_ node: RepositoryNode, context: ModuleContext) throws -> PullRequestsPayload {
        let connection = try node.decode(Node.self).m_prs_open
        let items = connection.nodes.map { pr in
            PullRequestSummary(
                number: pr.number, title: pr.title, url: pr.url, isDraft: pr.isDraft,
                createdAt: pr.createdAt, updatedAt: pr.updatedAt, branch: pr.headRefName,
                authorLogin: pr.author?.login,
                authorKind: classifier.classify(
                    AuthorInput(login: pr.author?.login, typeName: pr.author?.__typename, branch: pr.headRefName),
                    viewerLogin: context.viewerLogin
                ),
                ci: CIState(graphQL: pr.commits.nodes.last?.commit.statusCheckRollup?.state)
            )
        }
        return PullRequestsPayload(totalCount: connection.totalCount, items: items, hasMore: connection.pageInfo.hasNextPage)
    }

    public func summarize(_ payload: PullRequestsPayload, context: ModuleContext) -> ModuleSummary {
        var counts = ["open": payload.totalCount]
        for category in AuthorKind.Category.allCases {
            counts[category.rawValue] = payload.count(category)
        }
        let failingPersonPRs = payload.items.filter { $0.authorKind.isPerson && $0.ci == .failure }.count
        counts["ciFailing"] = payload.items.filter { $0.ci == .failure }.count
        counts["ciFailingPerson"] = failingPersonPRs
        // E7: Alarm nur bei PRs von Menschen (inkl. mir), nicht bei Bot-PRs.
        return ModuleSummary(counts: counts, needsAttention: failingPersonPRs > 0)
    }

    public func changes(from old: PullRequestsPayload?, to new: PullRequestsPayload, repository: RepoMeta) -> [Change] {
        guard let old else { return [] }
        return ItemDiff.changes(
            old: old.items.map(\.diffItem), new: new.items.map(\.diffItem), newHasMore: new.hasMore,
            module: Self.id, repository: repository
        )
    }
}

extension PullRequestSummary {
    var diffItem: ItemDiff.Item { ItemDiff.Item(number: number, title: title, url: url, updatedAt: updatedAt) }
}
