import Domain
import Foundation
import GitHubAPI
import ModuleKit

/// Gewichte des Aktivitätswerts (Konzept 7); später in den Einstellungen änderbar.
public struct ActivityWeights: Codable, Sendable, Equatable {
    public var commit = 3
    public var pullRequest = 2
    public var issue = 1
    public var pushWithin24h = 5
    public var pushWithin72h = 2

    public init() {}
    public static let `default` = ActivityWeights()
}

public struct ActivityPayload: ModulePayload {
    public let commits7d: Int
    public let commits30d: Int
    public let issuesOpened7d: Int
    public let issuesClosed7d: Int
    public let prsOpened7d: Int
    public let prsMerged7d: Int
    public let lastPush: Date?
    /// Wert nach Konzept 7, berechnet beim Dekodieren.
    public let score: Int
}

/// Aktivitätsstufe; die Schwellen ergeben sich relativ zu den eigenen Repos (`ActivityRanking`).
public enum ActivityLevel: Int, Codable, Sendable, Comparable, CaseIterable {
    case dormant, low, medium, high

    public static func < (lhs: ActivityLevel, rhs: ActivityLevel) -> Bool { lhs.rawValue < rhs.rawValue }
}

/// Aktivität pro Repo (Konzept 1 und 7).
public struct ActivityModule: InsightModule {
    public static let id = ModuleID("activity")

    public let metadata = ModuleMetadata(title: String(localized: "Aktivität"), systemImage: "waveform.path.ecg", defaultOrder: 30)
    public let weights: ActivityWeights

    public init(weights: ActivityWeights = .default) {
        self.weights = weights
    }

    public var fragment: GraphQLFragment {
        GraphQLFragment("""
        m_activity_pushedAt: pushedAt
        m_activity_branch: defaultBranchRef { target { ... on Commit {
          commits7d: history(since: $since7d) { totalCount }
          commits30d: history(since: $since30d) { totalCount }
        } } }
        m_activity_issues: issues(filterBy: {since: $updatedSince7d}, first: 50, orderBy: {field: UPDATED_AT, direction: DESC}) {
          nodes { createdAt closedAt }
        }
        m_activity_prs: pullRequests(first: 30, orderBy: {field: UPDATED_AT, direction: DESC}) {
          nodes { createdAt mergedAt }
        }
        """, variables: [.since7d, .since30d, .updatedSince7d])
    }

    private struct Node: Decodable {
        struct Count: Decodable { let totalCount: Int }
        struct Branch: Decodable {
            struct Target: Decodable {
                let commits7d: Count?
                let commits30d: Count?
            }
            let target: Target?
        }
        struct Items<Item: Decodable>: Decodable { let nodes: [Item] }
        struct Issue: Decodable {
            let createdAt: Date
            let closedAt: Date?
        }
        struct PullRequest: Decodable {
            let createdAt: Date
            let mergedAt: Date?
        }
        let m_activity_pushedAt: Date?
        let m_activity_branch: Branch?
        let m_activity_issues: Items<Issue>
        let m_activity_prs: Items<PullRequest>
    }

    public func decode(_ node: RepositoryNode, context: ModuleContext) throws -> ActivityPayload {
        let data = try node.decode(Node.self)
        let since = context.now.addingTimeInterval(-7 * 86_400)
        let recent: (Date?) -> Bool = { date in date.map { $0 >= since } ?? false }

        let commits7d = data.m_activity_branch?.target?.commits7d?.totalCount ?? 0
        let issuesOpened = data.m_activity_issues.nodes.filter { recent($0.createdAt) }.count
        let issuesClosed = data.m_activity_issues.nodes.filter { recent($0.closedAt) }.count
        let prsOpened = data.m_activity_prs.nodes.filter { recent($0.createdAt) }.count
        let prsMerged = data.m_activity_prs.nodes.filter { recent($0.mergedAt) }.count

        return ActivityPayload(
            commits7d: commits7d,
            commits30d: data.m_activity_branch?.target?.commits30d?.totalCount ?? 0,
            issuesOpened7d: issuesOpened,
            issuesClosed7d: issuesClosed,
            prsOpened7d: prsOpened,
            prsMerged7d: prsMerged,
            lastPush: data.m_activity_pushedAt,
            score: Self.score(
                commits: commits7d, pullRequests: prsOpened + prsMerged, issues: issuesOpened + issuesClosed,
                lastPush: data.m_activity_pushedAt, now: context.now, weights: weights
            )
        )
    }

    /// `3·Commits + 2·(PRs geöffnet + gemergt) + 1·(Issues geöffnet + geschlossen) + Frische` (Konzept 7).
    public static func score(commits: Int, pullRequests: Int, issues: Int, lastPush: Date?, now: Date, weights: ActivityWeights) -> Int {
        var score = weights.commit * commits + weights.pullRequest * pullRequests + weights.issue * issues
        if let lastPush {
            let age = now.timeIntervalSince(lastPush)
            if age < 24 * 3600 {
                score += weights.pushWithin24h
            } else if age < 72 * 3600 {
                score += weights.pushWithin72h
            }
        }
        return score
    }

    public func summarize(_ payload: ActivityPayload, context: ModuleContext) -> ModuleSummary {
        ModuleSummary(counts: [
            "score": payload.score,
            "commits7d": payload.commits7d,
            "commits30d": payload.commits30d,
            "issuesOpened7d": payload.issuesOpened7d,
            "issuesClosed7d": payload.issuesClosed7d,
            "prsOpened7d": payload.prsOpened7d,
            "prsMerged7d": payload.prsMerged7d,
        ])
    }
}

/// Stufen relativ zu den eigenen Repos (Konzept 7): Wert 0 = ruhend, die übrigen in Dritteln.
/// So bleibt die Einteilung bei 10 wie bei 300 Repos aussagekräftig.
public enum ActivityRanking {
    public static func levels(for scores: [String: Int]) -> [String: ActivityLevel] {
        let active = scores.values.filter { $0 > 0 }.sorted()
        guard !active.isEmpty else { return scores.mapValues { _ in .dormant } }
        let lowerThird = active[(active.count - 1) / 3]
        let upperThird = active[(2 * (active.count - 1)) / 3]
        return scores.mapValues { score in
            if score <= 0 { return .dormant }
            if score <= lowerThird { return .low }
            if score <= upperThird { return .medium }
            return .high
        }
    }
}
