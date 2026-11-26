import Domain
import Foundation
import GitHubAPI
import ModuleKit
import Testing
import TestSupport
@testable import Sync

@Suite("Refresh-Planer")
struct RefreshPlannerTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let planner = RefreshPlanner(favorites: ["o/liebling"])

    private func snapshot(_ id: String, name: String? = nil, lastActivityDaysAgo: Double, fetchedMinutesAgo: Double?,
                          frequent: Bool = false) -> RepoSnapshot {
        let activity = now.addingTimeInterval(-lastActivityDaysAgo * 86_400)
        return RepoSnapshot(
            meta: .fixture(id: id, name: name ?? "o/\(id)", pushedAt: activity, updatedAt: activity),
            summaries: frequent ? [ModuleID("x"): ModuleSummary(wantsFrequentRefresh: true)] : [:],
            detailsFetchedAt: fetchedMinutesAgo.map { now.addingTimeInterval(-$0 * 60) }
        )
    }

    private func state(_ repositories: [RepoSnapshot], inventoryMinutesAgo: Double = 1) -> SyncState {
        SyncState(viewerLogin: "v", inventoryFetchedAt: now.addingTimeInterval(-inventoryMinutesAgo * 60), repositories: repositories)
    }

    @Test("Stufen: Kurztakt, Favorit, aktiv, ruhend")
    func tiers() {
        #expect(planner.tier(of: snapshot("a", lastActivityDaysAgo: 100, fetchedMinutesAgo: 1, frequent: true), now: now) == .shortTick)
        #expect(planner.tier(of: snapshot("b", name: "o/liebling", lastActivityDaysAgo: 100, fetchedMinutesAgo: 1), now: now) == .active)
        #expect(planner.tier(of: snapshot("c", lastActivityDaysAgo: 2, fetchedMinutesAgo: 1), now: now) == .active)
        #expect(planner.tier(of: snapshot("d", lastActivityDaysAgo: 30, fetchedMinutesAgo: 1), now: now) == .dormant)
    }

    @Test("Ohne Bestand: alles")
    func firstRun() {
        let plan = planner.plan(for: SyncState(viewerLogin: ""), trigger: .timer, now: now)
        #expect(plan.inventory)
    }

    @Test("Takt: nur fällige Repos je Stufe")
    func timerPlansDueRepositories() {
        let plan = planner.plan(for: state([
            snapshot("aktiv-alt", lastActivityDaysAgo: 1, fetchedMinutesAgo: 6),
            snapshot("aktiv-frisch", lastActivityDaysAgo: 1, fetchedMinutesAgo: 2),
            snapshot("ruhend-frisch", lastActivityDaysAgo: 60, fetchedMinutesAgo: 20),
            snapshot("ruhend-alt", lastActivityDaysAgo: 60, fetchedMinutesAgo: 31),
            snapshot("kurztakt", lastActivityDaysAgo: 60, fetchedMinutesAgo: 1.5, frequent: true),
            snapshot("nie", lastActivityDaysAgo: 60, fetchedMinutesAgo: nil),
        ]), trigger: .timer, now: now)
        #expect(!plan.inventory)
        #expect(plan.repositoryIDs == ["aktiv-alt", "ruhend-alt", "kurztakt", "nie"])
    }

    @Test("Panel geöffnet: aktive Repos mit Daten älter als 1 Minute")
    func panelOpened() {
        let plan = planner.plan(for: state([
            snapshot("aktiv", lastActivityDaysAgo: 1, fetchedMinutesAgo: 2),
            snapshot("ruhend", lastActivityDaysAgo: 60, fetchedMinutesAgo: 2),
        ]), trigger: .panelOpened, now: now)
        #expect(plan.repositoryIDs == ["aktiv"])
    }

    @Test("Bestand ist nach 30 Minuten fällig, nach dem Aufwachen schon nach 5")
    func inventoryDue() {
        let repositories = [snapshot("a", lastActivityDaysAgo: 60, fetchedMinutesAgo: 1)]
        #expect(!planner.plan(for: state(repositories, inventoryMinutesAgo: 10), trigger: .timer, now: now).inventory)
        #expect(planner.plan(for: state(repositories, inventoryMinutesAgo: 31), trigger: .timer, now: now).inventory)
        #expect(planner.plan(for: state(repositories, inventoryMinutesAgo: 10), trigger: .wake, now: now).inventory)
        #expect(planner.plan(for: state(repositories, inventoryMinutesAgo: 1), trigger: .manual, now: now).inventory)
    }

    @Test("Nächste Fälligkeit")
    func nextDue() {
        let due = planner.nextDueDate(for: state([
            snapshot("aktiv", lastActivityDaysAgo: 1, fetchedMinutesAgo: 2),
        ], inventoryMinutesAgo: 1), now: now)
        #expect(due == now.addingTimeInterval(3 * 60))
    }
}

@Suite("Refresh-Scheduler", .timeLimit(.minutes(1)))
struct RefreshSchedulerTests {
    private func makeScheduler(_ github: FakeGitHub) throws -> (RefreshScheduler, SyncEngine) {
        let transport = HTTPTransport(tokenProvider: StaticTokenProvider("t"), session: github.session, retryPolicy: .none)
        let engine = SyncEngine(
            client: GraphQLClient(transport: transport, endpoint: github.graphQLEndpoint),
            rest: RESTClient(transport: transport, baseURL: github.baseURL),
            registry: try ModuleRegistry([AnyInsightModule(CountModule())])
        )
        // Kurze echte Pausen, damit die Schleife nicht leer dreht.
        let scheduler = RefreshScheduler(engine: engine, sleep: { _ in try await Task.sleep(for: .milliseconds(20)) })
        return (scheduler, engine)
    }

    private func nextEvent(_ iterator: inout AsyncStream<SyncEvent>.Iterator) async -> SyncEvent? {
        await iterator.next()
    }

    @Test("Start lädt alles, ein manueller Auslöser lädt sofort erneut")
    func startAndManualTrigger() async throws {
        let github = FakeGitHub(repos: [FakeGitHub.Repo(id: "R1", name: "o/eins", openIssues: 1)])
        let (scheduler, _) = try makeScheduler(github)
        var events = scheduler.events.makeAsyncIterator()

        await scheduler.start()
        guard case .started(let plan) = await nextEvent(&events) else { Issue.record("kein Start"); return }
        #expect(plan.inventory)
        guard case .finished(let outcome) = await nextEvent(&events) else { Issue.record("kein Ende"); return }
        #expect(outcome.state.repositories.count == 1)

        github.update { $0.repos[0].openIssues = 2 }
        await scheduler.trigger(.manual)
        guard case .started = await nextEvent(&events) else { Issue.record("kein zweiter Start"); return }
        guard case .finished(let second) = await nextEvent(&events) else { Issue.record("kein zweites Ende"); return }
        #expect(second.state.repositories[0].payload(CountPayload.self, for: CountModule.id)?.openIssues == 2)
        #expect(github.state.value.inventoryRequests == 2)

        await scheduler.stop()
    }

    @Test("Auslöser während eines laufenden Syncs wird danach ausgeführt")
    func triggerDuringSyncIsKept() async throws {
        let github = FakeGitHub(repos: [FakeGitHub.Repo(id: "R1", name: "o/eins")])
        let (scheduler, _) = try makeScheduler(github)
        var events = scheduler.events.makeAsyncIterator()

        await scheduler.start()
        // Erst auslösen, wenn der Start-Sync läuft. (Kommt der Auslöser vorher, wird er zu Recht
        // mit dem Start-Auslöser zusammengefasst.)
        guard case .started = await nextEvent(&events) else { Issue.record("kein Start"); return }
        await scheduler.trigger(.manual)
        var finished = 0
        while finished < 2, let event = await nextEvent(&events) {
            if case .finished = event { finished += 1 }
        }
        #expect(finished == 2)
        #expect(github.state.value.inventoryRequests == 2)
        await scheduler.stop()
    }

    @Test("Fehler wird gemeldet, mit Zeitpunkt des nächsten Versuchs")
    func reportsFailure() async throws {
        let github = FakeGitHub(repos: [])
        github.update { $0.inventoryStatus = 401 }
        let (scheduler, _) = try makeScheduler(github)
        var events = scheduler.events.makeAsyncIterator()

        await scheduler.start()
        _ = await nextEvent(&events)
        guard case .failed(let error, let retryAt) = await nextEvent(&events) else { Issue.record("kein Fehler"); return }
        #expect(error == .unauthorized)
        #expect(retryAt > Date())
        await scheduler.stop()
    }
}
