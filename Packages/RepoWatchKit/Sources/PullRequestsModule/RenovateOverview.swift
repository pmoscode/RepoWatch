import Domain
import Foundation

/// Renovate-PRs gruppiert nach Org → Repo (Renovate-Reiter). Reine Logik, damit testbar.
public enum RenovateOverview {
    /// Zähler nach CI-Status der PRs.
    public struct Counts: Sendable, Equatable {
        public var total = 0
        public var failing = 0
        public var passing = 0
        public var pending = 0
        /// PRs ohne Checks.
        public var unchecked = 0

        mutating func add(_ ci: CIState?) {
            total += 1
            switch ci {
            case .failure: failing += 1
            case .success: passing += 1
            case .pending: pending += 1
            case nil: unchecked += 1
            }
        }

        mutating func add(_ other: Counts) {
            total += other.total
            failing += other.failing
            passing += other.passing
            pending += other.pending
            unchecked += other.unchecked
        }
    }

    public struct RepositoryGroup: Sendable, Identifiable {
        public var id: String { repository.id }
        public let repository: RepoMeta
        /// Rote zuerst, dann nach letzter Änderung.
        public let pullRequests: [PullRequestSummary]
        public let counts: Counts
        /// Mehr offene PRs, als geladen wurden (Seitengröße des PR-Moduls).
        public let isIncomplete: Bool
        public let pullRequestsURL: URL
    }

    public struct OwnerGroup: Sendable, Identifiable {
        public var id: String { owner }
        public let owner: String
        public let repositories: [RepositoryGroup]
        public let counts: Counts
        public let pullRequestsURL: URL
    }

    /// Gruppen nach Org/Nutzer; Gruppen und Repos mit roten Checks zuerst, dann nach Anzahl.
    public static func groups(
        from repositories: [RepoSnapshot],
        viewerLogin: String,
        matches: (RepoMeta, PullRequestSummary) -> Bool = { _, _ in true }
    ) -> [OwnerGroup] {
        let repositoryGroups: [RepositoryGroup] = repositories.compactMap { snapshot in
            guard let payload = snapshot.payload(PullRequestsPayload.self, for: PullRequestsModule.id) else { return nil }
            let renovate = payload.items.filter { $0.authorKind == .renovate && matches(snapshot.meta, $0) }
            guard !renovate.isEmpty else { return nil }
            var counts = Counts()
            renovate.forEach { counts.add($0.ci) }
            return RepositoryGroup(
                repository: snapshot.meta,
                pullRequests: renovate.sorted {
                    ($0.ci == .failure ? 0 : 1, -$0.updatedAt.timeIntervalSince1970)
                        < ($1.ci == .failure ? 0 : 1, -$1.updatedAt.timeIntervalSince1970)
                },
                counts: counts,
                isIncomplete: payload.hasMore,
                pullRequestsURL: repositoryPullRequestsURL(for: snapshot.meta)
            )
        }

        return Dictionary(grouping: repositoryGroups) { String($0.repository.owner) }
            .map { owner, groups in
                var counts = Counts()
                groups.forEach { counts.add($0.counts) }
                return OwnerGroup(
                    owner: owner,
                    repositories: groups.sorted(by: attentionFirst),
                    counts: counts,
                    pullRequestsURL: ownerPullRequestsURL(owner: owner, isViewer: owner.caseInsensitiveCompare(viewerLogin) == .orderedSame)
                )
            }
            .sorted { lhs, rhs in
                (lhs.counts.failing > 0 ? 0 : 1, -lhs.counts.total, lhs.owner.lowercased())
                    < (rhs.counts.failing > 0 ? 0 : 1, -rhs.counts.total, rhs.owner.lowercased())
            }
    }

    private static func attentionFirst(_ lhs: RepositoryGroup, _ rhs: RepositoryGroup) -> Bool {
        (lhs.counts.failing > 0 ? 0 : 1, -lhs.counts.total, lhs.repository.nameWithOwner.lowercased())
            < (rhs.counts.failing > 0 ? 0 : 1, -rhs.counts.total, rhs.repository.nameWithOwner.lowercased())
    }

    // MARK: Titel

    /// Renovate-Titel ohne das immer gleiche Präfix, damit das Paket sichtbar bleibt:
    /// „chore(deps): update dependency foo to v2“ → „foo to v2“,
    /// „Update actions/checkout action to v5“ → „actions/checkout action to v5“.
    public static func shortTitle(_ title: String) -> String {
        var result = Substring(title)
        // Conventional-Commit-Präfix wie „chore(deps): “ oder „fix(deps)!: “
        if let colon = result.firstIndex(of: ":"), result[..<colon].allSatisfy({ $0.isLetter || "()-!_".contains($0) }) {
            result = result[result.index(after: colon)...].drop(while: \.isWhitespace)
        }
        for prefix in ["update dependency ", "update "] where result.lowercased().hasPrefix(prefix) {
            result = result.dropFirst(prefix.count)
            break
        }
        let short = String(result)
        return short.isEmpty ? title : short
    }

    // MARK: Links

    /// Suchfilter für Renovate-PRs (Mend-App, Login `renovate[bot]`).
    static let renovateQuery = "is:pr is:open author:app/renovate"

    /// PR-Liste des Repos auf GitHub, gefiltert auf offene Renovate-PRs.
    public static func repositoryPullRequestsURL(for repository: RepoMeta) -> URL {
        var components = URLComponents(url: repository.url.appending(path: "pulls"), resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "q", value: renovateQuery)]
        return components.url!
    }

    /// Alle offenen Renovate-PRs einer Org (bzw. des eigenen Kontos) in GitHubs PR-Suche.
    public static func ownerPullRequestsURL(owner: String, isViewer: Bool) -> URL {
        var components = URLComponents(string: "https://github.com/pulls")!
        components.queryItems = [URLQueryItem(name: "q", value: "\(renovateQuery) \(isViewer ? "user" : "org"):\(owner)")]
        return components.url!
    }
}
