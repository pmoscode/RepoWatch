import Domain
import Foundation
import GitHubAPI
import ModuleKit
import os

/// Lädt die Detail-Abfrage aller aktiven Module in Paketen (Konzept 4.1 und 4.3).
///
/// Die Paketgröße richtet sich nach der **Rechenzeit** bei GitHub, nicht nach Punkten: Im Spike
/// brach eine Abfrage für 25 Repos mit HTTP 502 ab. Ein 502/504 halbiert deshalb das Paket.
struct DetailFetcher: Sendable {
    struct Outcome: Sendable {
        var nodes: [String: RepositoryNode] = [:]
        /// Repo-ID → Fehlermeldung.
        var failures: [String: String] = [:]
        var stats = DetailStats()
        var rateLimit: RateLimitInfo?
    }

    let client: GraphQLClient
    let batchSize: Int
    let maxParallelBatches: Int
    private let logger = Logger(subsystem: "de.pmoscode.repowatch", category: "DetailFetcher")

    init(client: GraphQLClient, batchSize: Int, maxParallelBatches: Int) {
        self.client = client
        self.batchSize = max(1, batchSize)
        self.maxParallelBatches = max(1, maxParallelBatches)
    }

    func fetch(ids: [String], modules: [AnyInsightModule], now: Date) async throws -> Outcome {
        guard !ids.isEmpty, !modules.isEmpty else { return Outcome() }
        let query = QueryBuilder.detailQuery(for: modules)
        let batches = stride(from: 0, to: ids.count, by: batchSize).map {
            Array(ids[$0..<min($0 + batchSize, ids.count)])
        }

        var outcome = Outcome()
        try await withThrowingTaskGroup(of: Outcome.self) { group in
            var pending = batches.makeIterator()
            for _ in 0..<min(maxParallelBatches, batches.count) {
                if let batch = pending.next() {
                    group.addTask { try await fetchBatch(batch, query: query, modules: modules, now: now) }
                }
            }
            while let result = try await group.next() {
                outcome.merge(result)
                if let batch = pending.next() {
                    group.addTask { try await fetchBatch(batch, query: query, modules: modules, now: now) }
                }
            }
        }
        return outcome
    }

    private func fetchBatch(_ ids: [String], query: String, modules: [AnyInsightModule], now: Date) async throws -> Outcome {
        let operation = GraphQLOperation<DetailResponse>(
            name: QueryBuilder.operationName,
            query: query,
            variables: QueryBuilder.variables(for: modules, ids: ids, now: now)
        )
        let started = ContinuousClock.now
        var outcome = Outcome()
        do {
            let result = try await client.send(operation)
            let duration = ContinuousClock.now - started
            outcome.stats.requests = 1
            outcome.stats.cost = result.data.rateLimit?.cost ?? 0
            outcome.stats.slowestRequest = duration
            outcome.rateLimit = result.data.rateLimit?.info
            logger.info("Detail-Paket: \(ids.count) Repos, \(duration.formatted(.units(allowed: [.seconds, .milliseconds])), privacy: .public), Kosten \(outcome.stats.cost)")

            for (index, id) in ids.enumerated() {
                let node = index < result.data.nodes.count ? result.data.nodes[index] : .null
                if case .null = node {
                    let message = result.partialErrors.first { $0.path?.dropFirst().first == String(index) }?.message
                    if let message, let organization = AccessRestriction.organization(fromErrorMessage: message) {
                        outcome.failures[id] = String(localized: "Organisation \(organization) sperrt den Zugriff von RepoWatch (OAuth-Beschränkung).")
                    } else {
                        outcome.failures[id] = message ?? String(localized: "Repository nicht abrufbar")
                    }
                    continue
                }
                do {
                    let repositoryNode = try RepositoryNode(json: node)
                    outcome.nodes[repositoryNode.id] = repositoryNode
                } catch {
                    outcome.failures[id] = error.localizedDescription
                }
            }
        } catch let error as GitHubAPIError where error.indicatesTooHeavyQuery {
            guard ids.count > 1 else {
                outcome.failures[ids[0]] = error.localizedDescription
                return outcome
            }
            // Paket halbieren und beide Hälften nacheinander versuchen (Konzept 4.3).
            logger.notice("Detail-Paket mit \(ids.count) Repos zu schwer (\(error.localizedDescription, privacy: .public)), halbiere")
            let middle = ids.count / 2
            outcome.stats.halvings = 1
            outcome.merge(try await fetchBatch(Array(ids[..<middle]), query: query, modules: modules, now: now))
            outcome.merge(try await fetchBatch(Array(ids[middle...]), query: query, modules: modules, now: now))
        } catch let error as GitHubAPIError where !error.abortsSync {
            // Fehler, der nur dieses Paket betrifft: Repos behalten ihren alten Stand.
            for id in ids { outcome.failures[id] = error.localizedDescription }
        }
        return outcome
    }
}

public struct DetailStats: Sendable, Equatable {
    public var requests = 0
    public var cost = 0
    public var halvings = 0
    public var slowestRequest: Duration = .zero
}

extension DetailFetcher.Outcome {
    mutating func merge(_ other: DetailFetcher.Outcome) {
        nodes.merge(other.nodes) { _, new in new }
        failures.merge(other.failures) { _, new in new }
        stats.requests += other.stats.requests
        stats.cost += other.stats.cost
        stats.halvings += other.stats.halvings
        stats.slowestRequest = max(stats.slowestRequest, other.stats.slowestRequest)
        rateLimit = other.rateLimit ?? rateLimit
    }
}

struct DetailResponse: Decodable, Sendable {
    let nodes: [JSONValue]
    let rateLimit: InventoryResponse.RateLimit?
}

extension GitHubAPIError {
    /// GitHub bricht zu schwere Abfragen mit 502 oder 504 ab.
    var indicatesTooHeavyQuery: Bool {
        self == .server(status: 502) || self == .server(status: 504)
    }

    /// Fehler, bei denen weitere Anfragen in diesem Durchlauf sinnlos sind.
    var abortsSync: Bool {
        switch self {
        case .unauthorized, .offline, .rateLimited, .missingToken: true
        default: false
        }
    }
}
