import Domain
import Foundation
import ModuleKit

public struct ActionsPayload: ModulePayload {
    /// Gibt es `.github/workflows`? Ohne: „kein CI“ (Konzept 8.1).
    public let workflowFileCount: Int
    public let defaultBranch: String?
    /// Gesamtstatus des letzten Commits auf dem Standard-Branch, inkl. fremder Checks („CI allgemein“).
    public let headStatus: CIState?
    /// Runs der GitHub-Actions-Check-Suites am letzten Commit des Standard-Branches.
    public let headRuns: [WorkflowRunSummary]
    /// Letzte Runs über alle Branches aus REST `actions/runs`; nur für aktive Repos (Konzept 8.1).
    public let recentRuns: [WorkflowRunSummary]
    public let recentRunsFetchedAt: Date?

    public var hasWorkflows: Bool { workflowFileCount > 0 }

    /// Alle bekannten Runs ohne Doppelte (REST hat Vorrang).
    public var allRuns: [WorkflowRunSummary] {
        let restIDs = Set(recentRuns.map(\.id))
        return recentRuns + headRuns.filter { !restIDs.contains($0.id) }
    }

    public var workflowStates: [WorkflowState] { WorkflowAnalysis.states(of: allRuns) }
    public var defaultBranchStates: [WorkflowState] {
        workflowStates.filter { $0.branch == nil || $0.branch == defaultBranch }
    }
    public var isRunning: Bool { allRuns.contains { $0.outcome == .running } }

    func with(recentRuns: [WorkflowRunSummary], fetchedAt: Date?) -> ActionsPayload {
        ActionsPayload(
            workflowFileCount: workflowFileCount, defaultBranch: defaultBranch, headStatus: headStatus,
            headRuns: headRuns, recentRuns: recentRuns, recentRunsFetchedAt: fetchedAt
        )
    }
}

/// GitHub Actions: Status des Standard-Branches, Runs, Serien, Alarm (Konzept 8, E7).
public struct ActionsModule: InsightModule {
    public static let id = ModuleID("actions")
    public static let runsPerPage = 30
    /// Repos mit Push innerhalb dieses Zeitraums bekommen die REST-Run-Liste (Konzept 8.1: „nur aktive“).
    public static let activeWindow: TimeInterval = 7 * 86_400

    public let metadata = ModuleMetadata(title: String(localized: "Actions"), systemImage: "gearshape.2", defaultOrder: 40)
    private let rules: SharedValue<AuthorRules>
    /// Auslöser, die keinen Alarm auslösen (Einstellungen → Actions), z. B. `dynamic` für GitHubs eigene Läufe.
    private let ignoredEvents: SharedValue<Set<String>>
    private let now: @Sendable () -> Date

    public init(
        rules: SharedValue<AuthorRules> = SharedValue(.default),
        ignoredEvents: SharedValue<Set<String>> = SharedValue([]),
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.rules = rules
        self.ignoredEvents = ignoredEvents
        self.now = now
    }

    public var fragment: GraphQLFragment {
        GraphQLFragment("""
        m_actions_head: defaultBranchRef { name target { ... on Commit {
          statusCheckRollup { state }
          checkSuites(first: 10) { nodes {
            status conclusion app { slug }
            workflowRun { databaseId runNumber url createdAt updatedAt event workflow { name } }
          } }
        } } }
        m_actions_workflows: object(expression: "HEAD:.github/workflows") { ... on Tree { entries { name } } }
        """)
    }

    private struct Node: Decodable {
        struct Head: Decodable {
            struct Target: Decodable {
                struct Rollup: Decodable { let state: String }
                struct Suites: Decodable {
                    struct Suite: Decodable {
                        struct App: Decodable { let slug: String }
                        struct Run: Decodable {
                            struct Workflow: Decodable { let name: String }
                            let databaseId: Int64?
                            let runNumber: Int
                            let url: URL
                            let createdAt: Date
                            let updatedAt: Date
                            let event: String
                            let workflow: Workflow
                        }
                        let status: String
                        let conclusion: String?
                        let app: App?
                        let workflowRun: Run?
                    }
                    let nodes: [Suite]
                }
                let statusCheckRollup: Rollup?
                let checkSuites: Suites?
            }
            let name: String
            let target: Target?
        }
        struct Tree: Decodable {
            struct Entry: Decodable { let name: String }
            let entries: [Entry]?
        }
        let m_actions_head: Head?
        let m_actions_workflows: Tree?
    }

    public func decode(_ node: RepositoryNode, context: ModuleContext) throws -> ActionsPayload {
        let data = try node.decode(Node.self)
        let branch = data.m_actions_head?.name
        let headRuns: [WorkflowRunSummary] = (data.m_actions_head?.target?.checkSuites?.nodes ?? [])
            .filter { $0.app?.slug == "github-actions" }
            .compactMap { suite in
                guard let run = suite.workflowRun else { return nil }
                return WorkflowRunSummary(
                    id: run.databaseId ?? Int64(run.runNumber), workflowName: run.workflow.name,
                    runNumber: run.runNumber, attempt: 1,
                    outcome: RunOutcome(status: suite.status, conclusion: suite.conclusion),
                    branch: branch, event: run.event.lowercased(), actor: nil,
                    startedAt: run.createdAt, updatedAt: run.updatedAt, url: run.url, pullRequestNumbers: []
                )
            }
        let workflowFiles = (data.m_actions_workflows?.entries ?? [])
            .filter { $0.name.hasSuffix(".yml") || $0.name.hasSuffix(".yaml") }
        return ActionsPayload(
            workflowFileCount: workflowFiles.count,
            defaultBranch: branch,
            headStatus: CIState(graphQL: data.m_actions_head?.target?.statusCheckRollup?.state),
            headRuns: headRuns,
            recentRuns: [],
            recentRunsFetchedAt: nil
        )
    }

    // MARK: REST-Runs

    public func supplementaryRequests(for repository: RepoMeta, payload: ActionsPayload) -> [SupplementaryRequest] {
        guard payload.hasWorkflows else { return [] }
        let recentlyPushed = repository.pushedAt.map { now().timeIntervalSince($0) <= Self.activeWindow } ?? false
        let headNeedsLook = payload.headStatus == .failure || payload.headStatus == .pending || payload.isRunning
        guard recentlyPushed || headNeedsLook else { return [] }
        return [SupplementaryRequest(
            key: "runs",
            path: "/repos/\(repository.nameWithOwner)/actions/runs",
            query: [URLQueryItem(name: "per_page", value: String(Self.runsPerPage))]
        )]
    }

    struct RunsResponse: Decodable {
        struct Run: Decodable {
            struct Actor: Decodable { let login: String }
            struct PullRequest: Decodable { let number: Int }
            let id: Int64
            let name: String?
            let runNumber: Int
            let runAttempt: Int?
            let status: String?
            let conclusion: String?
            let headBranch: String?
            let event: String
            let actor: Actor?
            let runStartedAt: Date?
            let createdAt: Date
            let updatedAt: Date
            let htmlUrl: URL
            let pullRequests: [PullRequest]?
        }
        let workflowRuns: [Run]
    }

    public func merge(_ payload: ActionsPayload, with responses: [SupplementaryResponse], previous: ActionsPayload?) throws -> ActionsPayload {
        guard let response = responses.first(where: { $0.request.key == "runs" }),
              let runs = try? response.decode(RunsResponse.self) else {
            // Keine (erfolgreiche) Abfrage: letzte bekannte Runs behalten.
            return payload.with(recentRuns: previous?.recentRuns ?? [], fetchedAt: previous?.recentRunsFetchedAt)
        }
        let summaries = runs.workflowRuns.map { run in
            WorkflowRunSummary(
                id: run.id, workflowName: run.name ?? String(localized: "Workflow"), runNumber: run.runNumber,
                attempt: run.runAttempt ?? 1, outcome: RunOutcome(status: run.status, conclusion: run.conclusion),
                branch: run.headBranch, event: run.event, actor: run.actor?.login,
                startedAt: run.runStartedAt ?? run.createdAt, updatedAt: run.updatedAt, url: run.htmlUrl,
                pullRequestNumbers: run.pullRequests?.map(\.number) ?? []
            )
        }
        return payload.with(recentRuns: summaries, fetchedAt: now())
    }

    // MARK: Zusammenfassung und Alarm

    /// Autor-Art eines Runs: für PR-Läufe über Actor und Branch (Renovate-Branches, Bots).
    public func authorKind(of run: WorkflowRunSummary, viewerLogin: String) -> AuthorKind {
        AuthorClassifier.standard(rules.value).classify(AuthorInput(login: run.actor, branch: run.branch), viewerLogin: viewerLogin)
    }

    /// Workflow-Zustände, die nach E7 Alarm auslösen: Standard-Branch oder PR eines Menschen (inkl. mir).
    public func alertingStates(_ payload: ActionsPayload, viewerLogin: String) -> [WorkflowState] {
        let ignored = ignoredEvents.value
        return payload.workflowStates.filter { state in
            guard state.isFailing, !ignored.contains(state.latest.event) else { return false }
            if state.branch == nil || state.branch == payload.defaultBranch { return true }
            let run = state.latest
            return run.event.hasPrefix("pull_request") && authorKind(of: run, viewerLogin: viewerLogin).isPerson
        }
    }

    public func summarize(_ payload: ActionsPayload, context: ModuleContext) -> ModuleSummary {
        let states = payload.workflowStates
        let alerting = alertingStates(payload, viewerLogin: context.viewerLogin)
        // Roter Gesamtstatus zählt nicht, wenn er nur von ausgeblendeten Auslösern stammt.
        let failingHeadRuns = payload.headRuns.filter { $0.outcome == .failure }
        let onlyIgnoredFailures = !failingHeadRuns.isEmpty && failingHeadRuns.allSatisfy { ignoredEvents.value.contains($0.event) }
        let headFailing = payload.headStatus == .failure && !onlyIgnoredFailures
        return ModuleSummary(
            counts: [
                "workflows": payload.workflowFileCount,
                "failing": states.filter(\.isFailing).count,
                "alerting": alerting.count + (headFailing && alerting.isEmpty ? 1 : 0),
                "running": payload.allRuns.filter { $0.outcome == .running }.count,
            ],
            needsAttention: headFailing || !alerting.isEmpty,
            // Laufender Run: Kurztakt, bis er fertig ist (Konzept 4.2).
            wantsFrequentRefresh: payload.isRunning
        )
    }

    // MARK: Änderungen

    public func changes(from old: ActionsPayload?, to new: ActionsPayload, repository: RepoMeta) -> [Change] {
        guard let old else { return [] }
        let before = Dictionary(old.workflowStates.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return new.workflowStates.compactMap { state in
            guard state.branch == nil || state.branch == new.defaultBranch || state.latest.event.hasPrefix("pull_request"),
                  let previous = before[state.id]?.current, let current = state.current, previous != current
            else { return nil }
            let title = "\(state.workflowName) · \(state.branch ?? new.defaultBranch ?? "")"
            switch (previous, current) {
            case (.success, .failure):
                return Change(kind: .custom("workflowFailed"), repositoryID: repository.id, repositoryName: repository.nameWithOwner,
                              moduleID: Self.id, itemID: state.id, title: title, url: state.latest.url)
            case (.failure, .success):
                return Change(kind: .custom("workflowRecovered"), repositoryID: repository.id, repositoryName: repository.nameWithOwner,
                              moduleID: Self.id, itemID: state.id, title: title, url: state.latest.url)
            default:
                return nil
            }
        }
    }
}
