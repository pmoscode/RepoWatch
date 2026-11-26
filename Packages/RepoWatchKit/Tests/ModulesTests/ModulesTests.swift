import ActionsModule
import ActivityModule
import Domain
import Foundation
import GitHubAPI
import IssuesModule
import ModuleKit
import PullRequestsModule
import Testing
import TestSupport

/// Anonymisierte echte Repo-Knoten der Detail-Abfrage aller vier Module (Phase 3).
enum RealNodes {
    static func load() throws -> [RepositoryNode] {
        let url = try #require(Bundle.module.url(forResource: "detail-nodes", withExtension: "json", subdirectory: "Fixtures"))
        struct File: Decodable { let nodes: [JSONValue] }
        return try JSONDecoder().decode(File.self, from: Data(contentsOf: url)).nodes.map(RepositoryNode.init(json:))
    }
}

private let context = ModuleContext(viewerLogin: "viewer", now: Date())
private let meta = RepoMeta.fixture(id: "R1", name: "owner/repo", pushedAt: Date())

@Suite("Module gegen echte Antworten")
struct RealResponseTests {
    @Test("Die vier Module registrieren sich ohne Kollision")
    func registerTogether() throws {
        let registry = try ModuleRegistry([
            AnyInsightModule(IssuesModule()), AnyInsightModule(PullRequestsModule()),
            AnyInsightModule(ActivityModule()), AnyInsightModule(ActionsModule()),
        ])
        #expect(registry.modules.map(\.id.rawValue) == ["issues", "prs", "activity", "actions"])
    }

    @Test("Jeder Knoten ist für jedes Modul lesbar")
    func everyNodeDecodes() throws {
        let modules: [AnyInsightModule] = [
            AnyInsightModule(IssuesModule()), AnyInsightModule(PullRequestsModule()),
            AnyInsightModule(ActivityModule()), AnyInsightModule(ActionsModule()),
        ]
        let nodes = try RealNodes.load()
        #expect(nodes.count == 8)
        for node in nodes {
            for module in modules {
                #expect(throws: Never.self, "\(module.id) / \(node.id)") { _ = try module.decode(node, context: context) }
            }
        }
    }

    @Test("Issues: Zähler, Labels, Cursor")
    func issues() throws {
        let payloads = try RealNodes.load().map { try IssuesModule().decode($0, context: context) }
        let labelled = try #require(payloads.first { $0.items.contains { !$0.labels.isEmpty } })
        #expect(labelled.totalCount >= labelled.items.count)
        #expect(labelled.items.allSatisfy { $0.url.absoluteString.contains("/issues/") })
    }

    @Test("PRs: Renovate, Dependabot und Menschen werden erkannt, CI-Status gelesen")
    func pullRequests() throws {
        let module = PullRequestsModule()
        let payloads = try RealNodes.load().map { try module.decode($0, context: context) }
        let items = payloads.flatMap(\.items)
        #expect(items.contains { $0.authorKind == .renovate && $0.ci == .failure })
        #expect(items.contains { $0.authorKind == .dependabot })
        #expect(items.contains { $0.authorKind.isPerson })
        // Fehlschläge in Renovate-PRs lösen keinen Alarm aus (E7).
        let renovateOnly = try #require(payloads.first { $0.items.contains { $0.ci == .failure } && $0.items.allSatisfy { !$0.authorKind.isPerson } })
        #expect(module.summarize(renovateOnly, context: context).needsAttention == false)
    }

    @Test("Aktivität: Commits und Wert")
    func activity() throws {
        let payloads = try RealNodes.load().map { try ActivityModule().decode($0, context: context) }
        let busy = try #require(payloads.first { $0.commits7d > 0 })
        #expect(busy.commits30d >= busy.commits7d)
        #expect(busy.score >= 3 * busy.commits7d)
    }

    @Test("Actions: Status, Runs, ohne Workflows, leeres Repo")
    func actions() throws {
        let module = ActionsModule()
        let payloads = try RealNodes.load().map { try module.decode($0, context: context) }
        let failing = try #require(payloads.first { $0.headStatus == .failure })
        #expect(module.summarize(failing, context: context).needsAttention)
        let withRuns = try #require(payloads.first { !$0.headRuns.isEmpty })
        #expect(withRuns.hasWorkflows)
        #expect(withRuns.headRuns.allSatisfy { $0.branch == withRuns.defaultBranch })
        let noCI = try #require(payloads.first { !$0.hasWorkflows && $0.defaultBranch != nil })
        #expect(module.supplementaryRequests(for: meta, payload: noCI).isEmpty)
    }

    @Test("Leeres Repo ohne Standard-Branch: alle Module kommen damit klar")
    func emptyRepository() throws {
        let node = try RepositoryNode(json: try JSONDecoder().decode(JSONValue.self, from: Data(#"""
        {"id":"R_empty","m_issues_open":{"totalCount":0,"pageInfo":{"hasNextPage":false,"endCursor":null},"nodes":[]},
         "m_prs_open":{"totalCount":0,"pageInfo":{"hasNextPage":false},"nodes":[]},
         "m_activity_pushedAt":null,"m_activity_branch":null,"m_activity_issues":{"nodes":[]},"m_activity_prs":{"nodes":[]},
         "m_actions_head":null,"m_actions_workflows":null}
        """#.utf8)))
        let actions = try ActionsModule().decode(node, context: context)
        #expect(actions.defaultBranch == nil)
        #expect(!actions.hasWorkflows)
        #expect(try ActivityModule().decode(node, context: context).score == 0)
        #expect(try IssuesModule().decode(node, context: context).totalCount == 0)
        #expect(try PullRequestsModule().decode(node, context: context).items.isEmpty)
    }
}

@Suite("Autor-Einteilung")
struct AuthorClassifierTests {
    private let classifier = AuthorClassifier.standard(AuthorRules(renovateLogins: ["renovate", "renovate[bot]", "my-renovate-bot"]))

    @Test(arguments: [
        (AuthorInput(login: "renovate", typeName: "Bot", branch: "renovate/x"), AuthorKind.renovate),
        (AuthorInput(login: "renovate[bot]"), .renovate),
        (AuthorInput(login: "my-renovate-bot", typeName: "User", branch: "deps"), .renovate),
        (AuthorInput(login: "someone", typeName: "User", branch: "renovate/lockfile"), .renovate),
        (AuthorInput(login: "dependabot", typeName: "Bot", branch: "dependabot/npm/x"), .dependabot),
        (AuthorInput(login: "github-actions", typeName: "Bot"), .bot(name: "github-actions")),
        (AuthorInput(login: "release-please[bot]", typeName: "User"), .bot(name: "release-please")),
        (AuthorInput(login: "Viewer", typeName: "User", branch: "feat/x"), .me),
        (AuthorInput(login: "alice", typeName: "User", branch: "feat/y"), .human(login: "alice")),
        (AuthorInput(login: nil), .human(login: "ghost")),
    ])
    func classify(input: AuthorInput, expected: AuthorKind) {
        #expect(classifier.classify(input, viewerLogin: "viewer") == expected)
    }
}

@Suite("Einträge vergleichen")
struct ItemDiffTests {
    private func item(_ number: Int, updated: TimeInterval) -> ItemDiff.Item {
        ItemDiff.Item(number: number, title: "#\(number)", url: URL(string: "https://github.com/o/r/issues/\(number)")!,
                      updatedAt: Date(timeIntervalSince1970: updated))
    }

    @Test("Neu, geändert, geschlossen; verdrängt zählt nicht als geschlossen")
    func diff() {
        let old = [item(5, updated: 500), item(4, updated: 400), item(1, updated: 100)]
        let new = [item(7, updated: 700), item(5, updated: 550), item(3, updated: 300)]
        let changes = ItemDiff.changes(old: old, new: new, newHasMore: true, module: ModuleID("issues"), repository: meta)
        let summary = changes.map { "\($0.kind)#\($0.itemID ?? "")" }.sorted()
        // #7 neu, #5 geändert, #4 geschlossen (wäre noch im Fenster), #1 nur verdrängt, #3 nicht neu (Nummer zu klein).
        #expect(summary == ["itemClosed#4", "itemOpened#7", "itemUpdated#5"])
    }
}

@Suite("Aktivität")
struct ActivityTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    @Test("Wert nach Konzept 7 mit Frische-Bonus")
    func score() {
        let weights = ActivityWeights.default
        #expect(ActivityModule.score(commits: 2, pullRequests: 1, issues: 3, lastPush: nil, now: now, weights: weights) == 11)
        #expect(ActivityModule.score(commits: 0, pullRequests: 0, issues: 0, lastPush: now.addingTimeInterval(-3600), now: now, weights: weights) == 5)
        #expect(ActivityModule.score(commits: 0, pullRequests: 0, issues: 0, lastPush: now.addingTimeInterval(-48 * 3600), now: now, weights: weights) == 2)
        #expect(ActivityModule.score(commits: 0, pullRequests: 0, issues: 0, lastPush: now.addingTimeInterval(-96 * 3600), now: now, weights: weights) == 0)
    }

    @Test("Stufen in Dritteln der aktiven Repos, 0 = ruhend")
    func levels() {
        let levels = ActivityRanking.levels(for: ["a": 0, "b": 1, "c": 2, "d": 5, "e": 9, "f": 20, "g": 40])
        #expect(levels["a"] == .dormant)
        #expect(levels["b"] == .low)
        #expect(levels["c"] == .low)
        #expect(levels["d"] == .medium)
        #expect(levels["e"] == .medium)
        #expect(levels["f"] == .high)
        #expect(levels["g"] == .high)
        #expect(ActivityRanking.levels(for: ["x": 0]) == ["x": .dormant])
    }

    @Test("Ereignisse werden zugeordnet")
    func events() async throws {
        let body = #"""
        [
         {"id":"1","type":"PushEvent","actor":{"login":"alice"},"created_at":"2026-11-20T10:00:00Z","payload":{"ref":"refs/heads/main"}},
         {"id":"2","type":"PullRequestEvent","actor":{"login":"bob"},"created_at":"2026-11-20T11:00:00Z",
          "payload":{"action":"closed","pull_request":{"number":7,"title":"Fix","html_url":"https://github.com/o/r/pull/7","merged":true}}},
         {"id":"3","type":"IssuesEvent","actor":{"login":"carol"},"created_at":"2026-11-20T12:00:00Z",
          "payload":{"action":"opened","issue":{"number":8,"title":"Bug","html_url":"https://github.com/o/r/issues/8"}}},
         {"id":"4","type":"ReleaseEvent","actor":{"login":"dave"},"created_at":"2026-11-20T13:00:00Z","payload":{"release":{"tag_name":"v1.0"}}},
         {"id":"5","type":"GollumEvent","actor":{"login":"eve"},"created_at":"2026-11-20T14:00:00Z"}
        ]
        """#
        let (session, baseURL) = MockURLProtocol.makeSession { (.make(200, for: $0), Data(body.utf8)) }
        let rest = RESTClient(transport: HTTPTransport(tokenProvider: StaticTokenProvider("t"), session: session), baseURL: baseURL)
        let events = try await ActivityModule.fetchEvents(rest: rest, nameWithOwner: "o/r")
        #expect(events.map(\.kind) == [.push, .pullRequestMerged, .issueOpened, .release, .other])
        #expect(events[0].detail == "main")
        #expect(events[1].detail == "#7 Fix")
        #expect(events[3].detail == "v1.0")
    }
}

@Suite("Issues nachladen")
struct IssuePagingTests {
    @Test("Folgeseite mit Cursor")
    func fetchPage() async throws {
        let sentCursor = Locked<String?>(nil)
        let (session, baseURL) = MockURLProtocol.makeSession { request in
            let body = try JSONSerialization.jsonObject(with: request.bodyData ?? Data()) as? [String: Any] ?? [:]
            let cursor = (body["variables"] as? [String: Any])?["after"] as? String
            sentCursor.withLock { $0 = cursor }
            let response = #"""
            {"data":{"node":{"issues":{"totalCount":3,"pageInfo":{"hasNextPage":false,"endCursor":"c2"},"nodes":[
              {"number":3,"title":"Drei","url":"https://github.com/o/r/issues/3","createdAt":"2026-11-01T00:00:00Z",
               "updatedAt":"2026-11-02T00:00:00Z","author":null,"comments":{"totalCount":2},"labels":{"nodes":[{"name":"bug","color":"d73a4a"}]}}
            ]}}}}
            """#
            return (.make(200, for: request), Data(response.utf8))
        }
        let client = GraphQLClient(
            transport: HTTPTransport(tokenProvider: StaticTokenProvider("t"), session: session),
            endpoint: baseURL.appending(path: "graphql")
        )
        let page = try await IssuesModule.fetchPage(client: client, repositoryID: "R1", after: "c1")
        #expect(page.items.map(\.number) == [3])
        #expect(page.items[0].labels.map(\.name) == ["bug"])
        #expect(page.items[0].labels.map(\.color) == ["d73a4a"])
        #expect(page.items[0].author == nil)
        #expect(!page.hasMore)
        #expect(sentCursor.value == "c1")
    }
}
