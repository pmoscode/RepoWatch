import Domain
import Foundation
import ModuleKit

/// Test-Modul (Plan Phase 2): zählt offene Issues und kann eine REST-Folgeanfrage stellen.
public struct CountPayload: ModulePayload {
    public var openIssues: Int
    /// Wert aus der REST-Folgeanfrage, falls vorhanden.
    public var extra: String?

    public init(openIssues: Int, extra: String? = nil) {
        self.openIssues = openIssues
        self.extra = extra
    }
}

public struct CountModule: InsightModule {
    public static let id = ModuleID("count")
    public let metadata = ModuleMetadata(title: "Zähler", systemImage: "number", defaultOrder: 10)
    public let fragment = GraphQLFragment("m_count_issues: issues(states: OPEN) { totalCount }")
    /// Wenn gesetzt, fragt das Modul pro Repo `GET /repos/{name}/extra` ab.
    public let usesSupplementary: Bool

    public init(usesSupplementary: Bool = false) {
        self.usesSupplementary = usesSupplementary
    }

    private struct Node: Decodable {
        struct Count: Decodable { let totalCount: Int }
        let m_count_issues: Count
    }

    private struct Extra: Decodable { let value: String }

    public func decode(_ node: RepositoryNode, context: ModuleContext) throws -> CountPayload {
        CountPayload(openIssues: try node.decode(Node.self).m_count_issues.totalCount)
    }

    public func summarize(_ payload: CountPayload, context: ModuleContext) -> ModuleSummary {
        ModuleSummary(counts: ["open": payload.openIssues], needsAttention: payload.openIssues > 5)
    }

    public func supplementaryRequests(for repository: RepoMeta, payload: CountPayload) -> [SupplementaryRequest] {
        guard usesSupplementary else { return [] }
        return [SupplementaryRequest(key: "extra", path: "/repos/\(repository.nameWithOwner)/extra")]
    }

    public func merge(_ payload: CountPayload, with responses: [SupplementaryResponse], previous: CountPayload?) throws -> CountPayload {
        var merged = payload
        if let response = responses.first(where: { $0.request.key == "extra" }), let extra = try? response.decode(Extra.self) {
            merged.extra = extra.value
        } else {
            merged.extra = previous?.extra
        }
        return merged
    }

    public func changes(from old: CountPayload?, to new: CountPayload, repository: RepoMeta) -> [Change] {
        guard let old, new.openIssues > old.openIssues else { return [] }
        return [Change(kind: .itemOpened, repositoryID: repository.id, repositoryName: repository.nameWithOwner,
                       moduleID: Self.id, title: "+\(new.openIssues - old.openIssues)")]
    }
}

public extension RepoMeta {
    static func fixture(
        id: String,
        name: String,
        pushedAt: Date? = Date(timeIntervalSince1970: 1_800_000_000),
        updatedAt: Date = Date(timeIntervalSince1970: 1_800_000_000),
        isArchived: Bool = false,
        isFork: Bool = false
    ) -> RepoMeta {
        RepoMeta(
            id: id, nameWithOwner: name, url: URL(string: "https://github.com/\(name)")!,
            isPrivate: false, isFork: isFork, isArchived: isArchived,
            pushedAt: pushedAt, updatedAt: updatedAt, openIssueCount: 0, openPullRequestCount: 0
        )
    }
}
