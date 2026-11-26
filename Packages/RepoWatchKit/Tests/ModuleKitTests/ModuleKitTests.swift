import Domain
import Foundation
import Testing
import TestSupport
@testable import ModuleKit

/// Zweites Test-Modul mit einstellbarem Fragment für die Kollisionsprüfung.
private struct ProbeModule: InsightModule {
    struct Payload: ModulePayload { var value: Int }
    static let id = ModuleID("probe")
    let metadata = ModuleMetadata(title: "Probe", systemImage: "questionmark", defaultOrder: 5)
    let fragment: GraphQLFragment

    func decode(_ node: RepositoryNode, context: ModuleContext) throws -> Payload { Payload(value: 0) }
    func summarize(_ payload: Payload, context: ModuleContext) -> ModuleSummary { ModuleSummary() }
}

@Suite("Modul-Registry")
struct ModuleRegistryTests {
    @Test("Gültige Module werden nach Reihenfolge sortiert")
    func registersInOrder() throws {
        var registry = ModuleRegistry()
        try registry.register(CountModule())
        try registry.register(ProbeModule(fragment: GraphQLFragment("m_probe_x: stargazerCount")))
        #expect(registry.modules.map(\.id) == [ModuleID("probe"), ModuleID("count")])
    }

    @Test("Feld ohne Modul-Präfix wird abgelehnt")
    func rejectsUnprefixedField() {
        var registry = ModuleRegistry()
        #expect(throws: ModuleRegistryError.unprefixedField(module: ModuleID("probe"), field: "issues")) {
            try registry.register(ProbeModule(fragment: GraphQLFragment("issues(states: OPEN) { totalCount }")))
        }
        #expect(throws: ModuleRegistryError.unprefixedField(module: ModuleID("probe"), field: "m_count_x")) {
            try registry.register(ProbeModule(fragment: GraphQLFragment("m_count_x: stargazerCount")))
        }
    }

    @Test("Verschachtelte Felder brauchen kein Präfix, nur die oberste Ebene")
    func nestedFieldsAreFine() throws {
        var registry = ModuleRegistry()
        try registry.register(ProbeModule(fragment: GraphQLFragment("""
            m_probe_a: defaultBranchRef { target { ... on Commit { history(first: 1) { totalCount } } } }
            # Kommentar mit issues: drin
            m_probe_b: issues(filterBy: {since: $updatedSince7d}) { nodes { state } }
            """, variables: [.updatedSince7d])))
        #expect(registry.modules.count == 1)
    }

    @Test("Inline-Fragment auf oberster Ebene wird abgelehnt")
    func rejectsTopLevelFragment() {
        var registry = ModuleRegistry()
        #expect(throws: ModuleRegistryError.self) {
            try registry.register(ProbeModule(fragment: GraphQLFragment("... on Repository { m_probe_x: id }")))
        }
    }

    @Test("Doppeltes Modul wird abgelehnt")
    func rejectsDuplicateModule() throws {
        var registry = ModuleRegistry()
        try registry.register(CountModule())
        #expect(throws: ModuleRegistryError.duplicateModule(CountModule.id)) {
            try registry.register(CountModule())
        }
    }

    @Test("Abgeschaltete Module fehlen in enabledModules, ihre Payload-Typen bleiben bekannt")
    func disableModule() throws {
        var registry = try ModuleRegistry([AnyInsightModule(CountModule())])
        registry.setEnabled(false, for: CountModule.id)
        #expect(registry.enabledModules.isEmpty)
        #expect(registry.payloadTypes[CountModule.id] != nil)
    }
}

@Suite("QueryBuilder")
struct QueryBuilderTests {
    @Test("Abfrage aus zwei Modulen (Ausgabe-Snapshot)")
    func composesQuery() throws {
        let registry = try ModuleRegistry([
            AnyInsightModule(CountModule()),
            AnyInsightModule(ProbeModule(fragment: GraphQLFragment(
                "m_probe_commits: defaultBranchRef { target { ... on Commit { history(since: $since7d) { totalCount } } } }",
                variables: [.since7d]
            ))),
        ])
        let query = QueryBuilder.detailQuery(for: registry.enabledModules)
        #expect(query == """
        query RepositoryDetails($ids: [ID!]!, $since7d: GitTimestamp!) {
          nodes(ids: $ids) {
            ... on Repository {
              id
              # probe
              m_probe_commits: defaultBranchRef { target { ... on Commit { history(since: $since7d) { totalCount } } } }
              # count
              m_count_issues: issues(states: OPEN) { totalCount }
            }
          }
          rateLimit { cost remaining limit resetAt }
        }
        """)
    }

    @Test("Variablen: nur die benötigten, Zeitpunkte relativ zu jetzt")
    func variables() throws {
        let modules = [AnyInsightModule(ProbeModule(fragment: GraphQLFragment("m_probe_x: id", variables: [.since30d])))]
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let variables = QueryBuilder.variables(for: modules, ids: ["A", "B"], now: now)
        #expect(variables.count == 2)
        #expect(variables["ids"] == .strings(["A", "B"]))
        #expect(variables["since30d"] == .string(now.addingTimeInterval(-30 * 86_400).formatted(.iso8601)))
    }
}

@Suite("RepoSnapshot speichern")
struct RepoSnapshotCodingTests {
    private func roundTrip(_ snapshot: RepoSnapshot, types: [ModuleID: any ModulePayload.Type]) throws -> RepoSnapshot {
        let data = try JSONEncoder().encode(snapshot)
        let decoder = JSONDecoder()
        decoder.userInfo[.modulePayloadTypes] = types
        return try decoder.decode(RepoSnapshot.self, from: data)
    }

    private let snapshot = RepoSnapshot(
        meta: .fixture(id: "R1", name: "o/r"),
        payloads: [CountModule.id: AnyPayload(CountPayload(openIssues: 3, extra: "x"))],
        summaries: [CountModule.id: ModuleSummary(counts: ["open": 3])],
        detailsFetchedAt: Date(timeIntervalSince1970: 1_800_000_000)
    )

    @Test("Payload übersteht den Rundweg typisiert")
    func roundTripsPayload() throws {
        let decoded = try roundTrip(snapshot, types: [CountModule.id: CountPayload.self])
        #expect(decoded == snapshot)
        #expect(decoded.payload(CountPayload.self, for: CountModule.id)?.extra == "x")
    }

    @Test("Unbekanntes Modul: Payload verworfen, Repo wird neu abgefragt")
    func dropsUnknownModule() throws {
        let decoded = try roundTrip(snapshot, types: [:])
        #expect(decoded.payloads.isEmpty)
        #expect(decoded.summaries.isEmpty)
        #expect(decoded.detailsFetchedAt == nil)
    }
}
