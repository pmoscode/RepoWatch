import Darwin
import Domain
import Foundation

/// Welche Repos beobachtet werden (Konzept 3.3, Reiter „Repositories“).
/// Wird angewendet, **bevor** Details geladen werden; ausgefilterte Repos kosten nichts.
public struct SyncFilter: Codable, Sendable, Equatable {
    public var includeArchived: Bool
    public var includeForks: Bool
    /// Owner (Nutzer oder Organisation), deren Repos ausgeblendet werden.
    public var excludedOwners: Set<String>
    /// Glob-Muster auf `owner/name`, z. B. `pmoscode/old-*`. Groß-/Kleinschreibung egal.
    public var excludedPatterns: [String]

    public init(
        includeArchived: Bool = false,
        includeForks: Bool = true,
        excludedOwners: Set<String> = [],
        excludedPatterns: [String] = []
    ) {
        self.includeArchived = includeArchived
        self.includeForks = includeForks
        self.excludedOwners = excludedOwners
        self.excludedPatterns = excludedPatterns
    }

    public static let `default` = SyncFilter()

    public func includes(_ repository: RepoMeta) -> Bool {
        if repository.isArchived && !includeArchived { return false }
        if repository.isFork && !includeForks { return false }
        let owner = repository.owner.lowercased()
        if excludedOwners.contains(where: { $0.lowercased() == owner }) { return false }
        return !excludedPatterns.contains { pattern in
            fnmatch(pattern, repository.nameWithOwner, FNM_CASEFOLD) == 0
        }
    }
}
