import Domain
import Foundation
import GitHubAPI
import ModuleKit
import os
import Persistence

public struct SyncConfiguration: Sendable, Equatable {
    /// Repos pro Detail-Anfrage. 10 lässt Luft zum Zeitlimit von GitHub (Konzept 4.3).
    public var batchSize = 10
    /// Gleichzeitige Detail-Pakete; der `HTTPTransport` begrenzt zusätzlich alle Anfragen.
    public var parallelBatches = 3
    public var filter = SyncFilter.default

    public init(batchSize: Int = 10, parallelBatches: Int = 3, filter: SyncFilter = .default) {
        self.batchSize = batchSize
        self.parallelBatches = parallelBatches
        self.filter = filter
    }
}

/// Ergebnis eines Durchlaufs.
public struct SyncOutcome: Sendable {
    public let state: SyncState
    public let changes: ChangeSet
    public let stats: SyncStats
}

public struct SyncStats: Sendable, Equatable {
    public var inventoryCost = 0
    public var detail = DetailStats()
    public var supplementaryRequests = 0
    /// Davon mit `304 Not Modified` beantwortet (kostenlos).
    public var supplementaryNotModified = 0
    public var failedRepositories = 0
    public var signal = ChangeDetector.SignalObservation()
    public var duration: Duration = .zero
}

/// Hält den aktuellen Stand und führt Sync-Durchläufe aus (Konzept 9.3).
///
/// Ablauf: Bestand → Filter → Details in Paketen → Folgeanfragen der Module → Änderungen → speichern.
/// Fehler einzelner Repos oder Pakete brechen den Durchlauf nicht ab; diese Repos behalten ihren alten Stand.
public actor SyncEngine {
    private let inventoryFetcher: InventoryFetcher
    private let detailFetcher: DetailFetcher
    private let rest: RESTClient
    private var registry: ModuleRegistry
    private let store: (any SnapshotStore)?
    private let now: @Sendable () -> Date
    private var configuration: SyncConfiguration
    private var state: SyncState = .empty
    private let logger = Logger(subsystem: "de.pmoscode.repowatch", category: "SyncEngine")

    public init(
        client: GraphQLClient,
        rest: RESTClient,
        registry: ModuleRegistry,
        configuration: SyncConfiguration = SyncConfiguration(),
        store: (any SnapshotStore)? = nil,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        inventoryFetcher = InventoryFetcher(client: client)
        detailFetcher = DetailFetcher(
            client: client, batchSize: configuration.batchSize, maxParallelBatches: configuration.parallelBatches
        )
        self.rest = rest
        self.registry = registry
        self.configuration = configuration
        self.store = store
        self.now = now
    }

    public var currentState: SyncState { state }

    // MARK: Cache

    /// Lädt den gespeicherten Stand, damit die UI sofort etwas zeigt. Gibt `nil` zurück, wenn nichts da ist.
    @discardableResult
    public func restore() -> SyncState? {
        guard let store else { return nil }
        do {
            guard let restored = try store.load(payloadTypes: registry.payloadTypes) else { return nil }
            state = restored
            state.repositories = restored.repositories.filter { configuration.filter.includes($0.meta) }
            logger.info("Cache geladen: \(restored.repositories.count) Repos")
            return state
        } catch {
            logger.error("Cache unlesbar, wird verworfen: \(error.localizedDescription, privacy: .public)")
            try? store.clear()
            return nil
        }
    }

    /// Abmelden: Stand und Cache löschen (Konzept 11).
    public func reset() async {
        state = .empty
        try? store?.clear()
        await rest.clearCache()
    }

    /// Module an/aus (Einstellungen, Reiter „Module“). Abgeschaltete Module werden nicht mehr abgefragt.
    public func setModule(_ id: ModuleID, enabled: Bool) {
        registry.setEnabled(enabled, for: id)
    }

    public var filter: SyncFilter { configuration.filter }

    public func updateFilter(_ filter: SyncFilter) {
        configuration.filter = filter
        state.repositories = state.repositories.filter { filter.includes($0.meta) }
        // Neu eingeschlossene Repos kommen mit dem nächsten Bestand-Durchlauf.
        state.inventoryFetchedAt = nil
    }

    // MARK: Durchlauf

    public func sync(_ plan: SyncPlan) async throws -> SyncOutcome {
        let started = ContinuousClock.now
        let syncNow = now()
        let previous = state
        var next = state
        var stats = SyncStats()
        var detailIDs = plan.repositoryIDs

        if plan.inventory {
            let inventory = try await inventoryFetcher.fetchAll(now: { syncNow })
            stats.inventoryCost = inventory.totalCost
            let existing = Dictionary(uniqueKeysWithValues: previous.repositories.map { ($0.id, $0) })
            next.repositories = inventory.repositories
                .filter(configuration.filter.includes)
                .map { meta in
                    if var known = existing[meta.id] {
                        known.meta = meta
                        return known
                    }
                    detailIDs.insert(meta.id)
                    return RepoSnapshot(meta: meta)
                }
            next.viewerLogin = inventory.viewerLogin
            next.inventoryFetchedAt = syncNow
            next.rateLimit = inventory.rateLimit
        }

        let tracked = Set(next.repositories.map(\.id))
        if plan.allRepositories {
            detailIDs = tracked
        }
        detailIDs.formIntersection(tracked)
        let modules = registry.enabledModules
        let context = ModuleContext(viewerLogin: next.viewerLogin, now: syncNow)

        if modules.isEmpty {
            // Ohne Module gibt es keine Details; als „abgefragt“ markieren, damit der Planer Ruhe gibt.
            for index in next.repositories.indices where detailIDs.contains(next.repositories[index].id) {
                next.repositories[index].detailsFetchedAt = syncNow
            }
        } else if !detailIDs.isEmpty {
            // Reihenfolge wie in der Liste, damit aktive Repos in den ersten Paketen landen.
            let orderedIDs = next.repositories.map(\.id).filter(detailIDs.contains)
            let outcome = try await detailFetcher.fetch(ids: orderedIDs, modules: modules, now: syncNow)
            stats.detail = outcome.stats
            stats.failedRepositories = outcome.failures.count
            if let rateLimit = outcome.rateLimit { next.rateLimit = rateLimit }

            var supplementaryWork: [(index: Int, module: AnyInsightModule, requests: [SupplementaryRequest])] = []
            for index in next.repositories.indices {
                let id = next.repositories[index].id
                guard detailIDs.contains(id) else { continue }
                if let failure = outcome.failures[id] {
                    next.repositories[index].lastDetailError = failure
                    continue
                }
                guard let node = outcome.nodes[id] else { continue }
                apply(node: node, modules: modules, context: context, to: &next.repositories[index])
                for module in modules {
                    guard let payload = next.repositories[index].payloads[module.id] else { continue }
                    // Auch ohne Folgeanfragen: `merge` darf Daten aus dem letzten Durchlauf übernehmen.
                    let requests = module.supplementaryRequests(for: next.repositories[index].meta, payload: payload.value)
                    supplementaryWork.append((index, module, requests))
                }
            }

            let responses = await performSupplementary(supplementaryWork.flatMap(\.requests))
            stats.supplementaryRequests = responses.count
            let previousByID = Dictionary(uniqueKeysWithValues: previous.repositories.map { ($0.id, $0) })
            stats.supplementaryNotModified = responses.values.filter(\.isFromCache).count
            for work in supplementaryWork {
                let index = work.index
                let id = next.repositories[index].id
                guard let payload = next.repositories[index].payloads[work.module.id] else { continue }
                do {
                    let merged = try work.module.merge(
                        payload.value,
                        with: work.requests.compactMap { responses[$0] },
                        previous: previousByID[id]?.payloads[work.module.id]?.value
                    )
                    next.repositories[index].payloads[work.module.id] = AnyPayload(merged)
                    next.repositories[index].summaries[work.module.id] = work.module.summarize(merged, context: context)
                } catch {
                    logger.error("Modul \(work.module.id.rawValue, privacy: .public): Folgeanfragen nicht verwertbar: \(error.localizedDescription, privacy: .public)")
                }
            }
        }

        next.repositories.sort { ($0.meta.pushedAt ?? .distantPast) > ($1.meta.pushedAt ?? .distantPast) }
        next.lastSyncAt = syncNow

        let (changes, signal) = ChangeDetector.detect(
            old: previous, new: next, refreshedIDs: detailIDs,
            inventoryRefreshed: plan.inventory, modules: modules, now: syncNow
        )
        stats.signal = signal
        stats.duration = ContinuousClock.now - started

        // Erst übernehmen, wenn alles durch ist: Ein abgebrochener Durchlauf hinterlässt keinen halben Stand.
        try Task.checkCancellation()
        state = next
        persist()
        log(plan: plan, stats: stats, changes: changes)
        return SyncOutcome(state: next, changes: changes, stats: stats)
    }

    // MARK: Hilfen

    private func apply(node: RepositoryNode, modules: [AnyInsightModule], context: ModuleContext, to snapshot: inout RepoSnapshot) {
        var failed: [String] = []
        let repositoryName = snapshot.meta.nameWithOwner
        for module in modules {
            do {
                let payload = try module.decode(node, context: context)
                snapshot.payloads[module.id] = AnyPayload(payload)
                snapshot.summaries[module.id] = module.summarize(payload, context: context)
            } catch {
                // Alten Payload behalten; das Repo wird beim nächsten Takt erneut versucht.
                failed.append(module.id.rawValue)
                logger.error("Modul \(module.id.rawValue, privacy: .public) konnte \(repositoryName, privacy: .private) nicht lesen: \(String(describing: error), privacy: .public)")
            }
        }
        snapshot.lastDetailError = failed.isEmpty ? nil : String(localized: "Module nicht lesbar: \(failed.joined(separator: ", "))")
        snapshot.detailsFetchedAt = failed.isEmpty ? context.now : snapshot.detailsFetchedAt
    }

    private func performSupplementary(_ requests: [SupplementaryRequest]) async -> [SupplementaryRequest: SupplementaryResponse] {
        guard !requests.isEmpty else { return [:] }
        let unique = Array(Set(requests))
        return await withTaskGroup(of: SupplementaryResponse.self) { group in
            for request in unique {
                group.addTask { [rest] in
                    do {
                        let response = try await rest.getData(request.path, query: request.query)
                        return SupplementaryResponse(request: request, result: .success(response.value), isFromCache: response.isFromCache)
                    } catch let error as GitHubAPIError {
                        return SupplementaryResponse(request: request, result: .failure(error), isFromCache: false)
                    } catch {
                        return SupplementaryResponse(request: request, result: .failure(.transport(error.localizedDescription)), isFromCache: false)
                    }
                }
            }
            var result: [SupplementaryRequest: SupplementaryResponse] = [:]
            for await response in group {
                result[response.request] = response
            }
            return result
        }
    }

    private func persist() {
        guard let store else { return }
        do {
            try store.save(state)
        } catch {
            logger.error("Cache nicht gespeichert: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func log(plan: SyncPlan, stats: SyncStats, changes: ChangeSet) {
        logger.info("""
        Sync fertig in \(stats.duration.formatted(.units(allowed: [.seconds, .milliseconds])), privacy: .public): \
        Bestand=\(plan.inventory), Details=\(plan.allRepositories ? "alle" : String(plan.repositoryIDs.count), privacy: .public) Repos in \(stats.detail.requests) Anfragen \
        (Kosten \(stats.inventoryCost + stats.detail.cost), Halbierungen \(stats.detail.halvings), \
        langsamste \(stats.detail.slowestRequest.formatted(.units(allowed: [.seconds, .milliseconds])), privacy: .public)), \
        REST \(stats.supplementaryRequests) (davon 304: \(stats.supplementaryNotModified)), \
        Fehler \(stats.failedRepositories), Änderungen \(changes.changes.count)
        """)
        if stats.signal.signalled + stats.signal.missed > 0 {
            // Offene Frage aus Phase 0 (Plan, Phase 2): Taugen pushedAt/updatedAt als Signal?
            logger.notice("Aktivitäts-Signal: \(stats.signal.signalled) mit, \(stats.signal.missed) ohne Änderung an pushedAt/updatedAt")
        }
    }
}
