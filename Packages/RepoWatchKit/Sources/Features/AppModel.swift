import Auth
import Domain
import Foundation
import GitHubAPI
import Observation
import Sync
import os

/// Zentraler UI-Zustand (Konzept 9.3). In Phase 0 nur der Bestand aller Repos.
@MainActor
@Observable
public final class AppModel {
    public enum LoadState: Equatable {
        case idle
        case loading
        case loaded
        case failed(String)
    }

    public private(set) var state: LoadState = .idle
    public private(set) var inventory: InventorySnapshot?
    public let hasToken: Bool

    private let fetcher: InventoryFetcher
    private var refreshTask: Task<Void, Never>?
    private let logger = Logger(subsystem: "de.pmoscode.repowatch", category: "AppModel")

    public init() {
        let tokenProvider = EnvironmentTokenProvider()
        hasToken = tokenProvider.isAvailable
        fetcher = InventoryFetcher(client: GraphQLClient(tokenProvider: tokenProvider))
    }

    /// Repos, die nicht archiviert sind, zuletzt gepusht zuerst.
    public var visibleRepositories: [RepoMeta] {
        (inventory?.repositories ?? []).filter { !$0.isArchived }
    }

    public func refresh() {
        guard hasToken else {
            state = .failed(String(localized: "GITHUB_TOKEN ist nicht gesetzt."))
            return
        }
        refreshTask?.cancel()
        state = .loading
        refreshTask = Task { [fetcher, logger] in
            do {
                let snapshot = try await fetcher.fetchAll()
                guard !Task.isCancelled else { return }
                logger.info(
                    "Bestand geladen: \(snapshot.repositories.count) Repos, \(snapshot.pageCount) Seite(n), Kosten \(snapshot.totalCost)"
                )
                self.inventory = snapshot
                self.state = .loaded
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled else { return }
                logger.error("Bestand fehlgeschlagen: \(error.localizedDescription, privacy: .public)")
                self.state = .failed(error.localizedDescription)
            }
        }
    }
}
