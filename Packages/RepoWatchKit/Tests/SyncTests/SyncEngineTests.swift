import Domain
import Foundation
import GitHubAPI
import ModuleKit
import Persistence
import Testing
import TestSupport
@testable import Sync

/// Baut eine Engine gegen den `FakeGitHub`-Simulator.
private func makeEngine(
    _ github: FakeGitHub,
    module: CountModule = CountModule(),
    batchSize: Int = 10,
    filter: SyncFilter = .default,
    store: (any SnapshotStore)? = nil
) throws -> SyncEngine {
    let transport = HTTPTransport(tokenProvider: StaticTokenProvider("t"), session: github.session, retryPolicy: .none)
    return SyncEngine(
        client: GraphQLClient(transport: transport, endpoint: github.graphQLEndpoint),
        rest: RESTClient(transport: transport, baseURL: github.baseURL),
        registry: try ModuleRegistry([AnyInsightModule(module)]),
        configuration: SyncConfiguration(batchSize: batchSize, parallelBatches: 2, filter: filter),
        store: store
    )
}

private let full = SyncPlan.full

@Suite("SyncEngine")
struct SyncEngineTests {
    private let repos = [
        FakeGitHub.Repo(id: "R1", name: "o/eins", openIssues: 1),
        FakeGitHub.Repo(id: "R2", name: "o/zwei", openIssues: 2),
        FakeGitHub.Repo(id: "R3", name: "o/alt", isArchived: true, openIssues: 3),
        FakeGitHub.Repo(id: "R4", name: "o/spielwiese-1", openIssues: 4),
        FakeGitHub.Repo(id: "R5", name: "org/fuenf", openIssues: 5),
    ]

    @Test("Voller Durchlauf: Filter vor den Details, Pakete, Payloads und Zusammenfassungen")
    func fullSync() async throws {
        let github = FakeGitHub(repos: repos)
        let engine = try makeEngine(github, batchSize: 2, filter: SyncFilter(excludedPatterns: ["o/spielwiese-*"]))

        let outcome = try await engine.sync(full)

        let ids = Set(outcome.state.repositories.map(\.id))
        #expect(ids == ["R1", "R2", "R5"])
        // Archiviertes und ausgeschlossenes Repo wurden gar nicht erst abgefragt.
        #expect(github.state.value.detailBatchSizes.sorted() == [1, 2])
        let r5 = try #require(outcome.state.repositories.first { $0.id == "R5" })
        #expect(r5.payload(CountPayload.self, for: CountModule.id)?.openIssues == 5)
        #expect(r5.summaries[CountModule.id]?.counts["open"] == 5)
        #expect(r5.detailsFetchedAt != nil)
        #expect(outcome.state.viewerLogin == "viewer")
        // Erster Durchlauf: keine „neu“-Meldungen für alles.
        #expect(outcome.changes.isEmpty)
    }

    @Test("HTTP 502: Paket wird halbiert, alle Repos kommen trotzdem an")
    func halvesOnBadGateway() async throws {
        let github = FakeGitHub(repos: repos.filter { !$0.isArchived })
        github.update { $0.maxBatchSize = 1 }
        let engine = try makeEngine(github, batchSize: 4)

        let outcome = try await engine.sync(full)

        #expect(outcome.stats.detail.halvings >= 2)
        #expect(outcome.stats.failedRepositories == 0)
        #expect(outcome.state.repositories.allSatisfy { $0.payloads[CountModule.id] != nil })
        #expect(github.state.value.detailBatchSizes.first == 4)
    }

    @Test("Nicht abrufbares Repo behält den alten Stand und bekommt eine Fehlermeldung")
    func unreadableRepositoryKeepsPreviousPayload() async throws {
        let github = FakeGitHub(repos: Array(repos.prefix(2)))
        let engine = try makeEngine(github)
        _ = try await engine.sync(full)

        github.update {
            $0.unreadableIDs = ["R1"]
            $0.repos[0].openIssues = 9
        }
        let outcome = try await engine.sync(SyncPlan(inventory: false, repositoryIDs: ["R1", "R2"]))

        let r1 = try #require(outcome.state.repositories.first { $0.id == "R1" })
        #expect(r1.payload(CountPayload.self, for: CountModule.id)?.openIssues == 1)
        #expect(r1.lastDetailError == "Resource not accessible")
        #expect(outcome.stats.failedRepositories == 1)
    }

    @Test("Änderungen: Modul-Änderung, neues Repo, Push")
    func detectsChanges() async throws {
        let github = FakeGitHub(repos: Array(repos.prefix(2)))
        let engine = try makeEngine(github)
        _ = try await engine.sync(full)

        github.update {
            $0.repos[0].openIssues = 3
            $0.repos[1].pushedAt = Date(timeIntervalSince1970: 1_900_000_000)
            $0.repos.append(FakeGitHub.Repo(id: "R9", name: "o/neu"))
        }
        let outcome = try await engine.sync(full)

        let kinds = outcome.changes.changes.map { "\($0.repositoryID):\($0.kind)" }.sorted()
        #expect(kinds == ["R1:itemOpened", "R2:pushed", "R9:repositoryAdded"])
        // R1 hatte eine Modul-Änderung ohne geänderte pushedAt/updatedAt (Signal-Beobachtung).
        #expect(outcome.stats.signal.missed == 1)
    }

    @Test("Folgeanfrage mit ETag: zweiter Durchlauf bekommt 304 und behält den Wert")
    func supplementaryWithETag() async throws {
        let github = FakeGitHub(repos: [repos[0]])
        let engine = try makeEngine(github, module: CountModule(usesSupplementary: true))

        let first = try await engine.sync(full)
        let second = try await engine.sync(SyncPlan(inventory: false, repositoryIDs: ["R1"]))

        #expect(first.state.repositories[0].payload(CountPayload.self, for: CountModule.id)?.extra == "eins")
        #expect(second.state.repositories[0].payload(CountPayload.self, for: CountModule.id)?.extra == "eins")
        #expect(github.state.value.restStatuses == [200, 304])
        #expect(second.stats.supplementaryNotModified == 1)
    }

    @Test("Cache: zweiter Start zeigt den Stand ohne Netz")
    func restoresFromStore() async throws {
        let github = FakeGitHub(repos: Array(repos.prefix(2)))
        let store = InMemorySnapshotStore()
        let first = try await makeEngine(github, store: store).sync(full)

        let offline = FakeGitHub(repos: [])
        offline.update { $0.inventoryStatus = 500 }
        let restarted = try makeEngine(offline, store: store)
        let restored = await restarted.restore()

        #expect(restored == first.state)
        #expect(restored?.repositories.first?.payload(CountPayload.self, for: CountModule.id) != nil)
        #expect(offline.state.value.inventoryRequests == 0)
    }

    @Test("401 bricht ab und lässt den Stand unverändert")
    func unauthorizedAborts() async throws {
        let github = FakeGitHub(repos: Array(repos.prefix(2)))
        let engine = try makeEngine(github)
        let before = try await engine.sync(full).state

        github.update { $0.inventoryStatus = 401 }
        await #expect(throws: GitHubAPIError.unauthorized) {
            _ = try await engine.sync(full)
        }
        #expect(await engine.currentState == before)
    }

    @Test("Abmelden löscht Stand und Cache")
    func resetClears() async throws {
        let github = FakeGitHub(repos: [repos[0]])
        let store = InMemorySnapshotStore()
        let engine = try makeEngine(github, store: store)
        _ = try await engine.sync(full)
        #expect(store.hasData)

        await engine.reset()
        #expect(await engine.currentState == .empty)
        #expect(!store.hasData)
    }
}

@Suite("Filter")
struct SyncFilterTests {
    @Test func rules() {
        let filter = SyncFilter(includeForks: false, excludedOwners: ["Alte-Org"], excludedPatterns: ["me/test-*"])
        #expect(filter.includes(.fixture(id: "1", name: "me/app")))
        #expect(!filter.includes(.fixture(id: "2", name: "me/app", isArchived: true)))
        #expect(!filter.includes(.fixture(id: "3", name: "me/app", isFork: true)))
        #expect(!filter.includes(.fixture(id: "4", name: "alte-org/x")))
        #expect(!filter.includes(.fixture(id: "5", name: "me/TEST-1")))
    }
}
