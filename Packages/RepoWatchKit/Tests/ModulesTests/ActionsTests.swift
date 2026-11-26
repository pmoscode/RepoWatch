import ActionsModule
import Domain
import Foundation
import GitHubAPI
import ModuleKit
import Testing
import TestSupport

private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

private func run(
    _ id: Int64, workflow: String = "CI", branch: String? = "main", outcome: RunOutcome,
    minutesAgo: Double, event: String = "push", actor: String? = "alice"
) -> WorkflowRunSummary {
    WorkflowRunSummary(
        id: id, workflowName: workflow, runNumber: Int(id), attempt: 1, outcome: outcome, branch: branch,
        event: event, actor: actor, startedAt: t0.addingTimeInterval(-minutesAgo * 60),
        updatedAt: t0.addingTimeInterval(-minutesAgo * 60 + 90),
        url: URL(string: "https://github.com/o/r/actions/runs/\(id)")!, pullRequestNumbers: []
    )
}

private func payload(head: CIState? = .success, runs: [WorkflowRunSummary], workflows: Int = 2) -> ActionsPayload {
    // Über JSON bauen, damit der Test nur die öffentliche Schnittstelle nutzt.
    let encoder = JSONEncoder()
    let runsJSON = String(decoding: try! encoder.encode(runs), as: UTF8.self)
    let json = """
    {"workflowFileCount":\(workflows),"defaultBranch":"main",\(head.map { #""headStatus":"\#($0.rawValue)","# } ?? "")
     "headRuns":[],"recentRuns":\(runsJSON)}
    """
    return try! JSONDecoder().decode(ActionsPayload.self, from: Data(json.utf8))
}

@Suite("Actions: Status-Zuordnung")
struct RunOutcomeTests {
    @Test(arguments: [
        ("completed", "success" as String?, RunOutcome.success),
        ("completed", "failure", .failure),
        ("completed", "timed_out", .failure),
        ("completed", "startup_failure", .failure),
        ("completed", "cancelled", .cancelled),
        ("completed", "skipped", .skipped),
        ("completed", "neutral", .skipped),
        ("completed", "stale", .skipped),
        ("completed", "action_required", .actionRequired),
        ("in_progress", nil, .running),
        ("queued", nil, .running),
        ("waiting", nil, .running),
        ("COMPLETED", "FAILURE", .failure),
        ("IN_PROGRESS", nil, .running),
    ])
    func mapping(status: String, conclusion: String?, expected: RunOutcome) {
        #expect(RunOutcome(status: status, conclusion: conclusion) == expected)
    }
}

@Suite("Actions: Ableitungen")
struct WorkflowAnalysisTests {
    @Test("Rot seit, Fehlschläge in Folge, Erfolgsquote; Abbrüche zählen nicht")
    func streak() throws {
        let states = WorkflowAnalysis.states(of: [
            run(5, outcome: .running, minutesAgo: 1),
            run(4, outcome: .failure, minutesAgo: 10),
            run(3, outcome: .cancelled, minutesAgo: 20),
            run(2, outcome: .failure, minutesAgo: 30),
            run(1, outcome: .success, minutesAgo: 40),
        ])
        let state = try #require(states.first)
        #expect(states.count == 1)
        #expect(state.isFailing)
        #expect(state.isRunning)
        #expect(state.latest.id == 5)
        #expect(state.consecutiveFailures == 2)
        #expect(state.failingSince == t0.addingTimeInterval(-30 * 60))
        #expect(state.successRate == 1.0 / 3.0)
    }

    @Test("Getrennt nach Workflow und Branch, Fehlschläge zuerst")
    func grouping() {
        let states = WorkflowAnalysis.states(of: [
            run(1, workflow: "Build", outcome: .success, minutesAgo: 5),
            run(2, workflow: "Build", branch: "feat", outcome: .failure, minutesAgo: 5),
            run(3, workflow: "Lint", outcome: .success, minutesAgo: 5),
        ])
        #expect(states.map(\.id) == ["Build@feat", "Build@main", "Lint@main"])
    }
}

@Suite("Actions: Modul")
struct ActionsModuleTests {
    private let context = ModuleContext(viewerLogin: "viewer", now: t0)

    @Test("Alarm (E7): Standard-Branch und Menschen-PR ja, Renovate-PR nein")
    func alerting() {
        let module = ActionsModule(now: { t0 })
        let mainFailing = payload(runs: [run(1, outcome: .failure, minutesAgo: 5)])
        #expect(module.summarize(mainFailing, context: context).needsAttention)

        let humanPR = payload(runs: [run(2, branch: "feat/x", outcome: .failure, minutesAgo: 5, event: "pull_request", actor: "alice")])
        #expect(module.summarize(humanPR, context: context).needsAttention)

        let renovatePR = payload(runs: [run(3, branch: "renovate/foo", outcome: .failure, minutesAgo: 5, event: "pull_request", actor: "renovate[bot]")])
        #expect(!module.summarize(renovatePR, context: context).needsAttention)
        #expect(module.summarize(renovatePR, context: context).counts["failing"] == 1)

        let recovered = payload(runs: [run(5, outcome: .success, minutesAgo: 1), run(4, outcome: .failure, minutesAgo: 9)])
        #expect(!module.summarize(recovered, context: context).needsAttention)
    }

    @Test("Laufender Run → Kurztakt")
    func frequentRefresh() {
        let module = ActionsModule(now: { t0 })
        #expect(module.summarize(payload(runs: [run(1, outcome: .running, minutesAgo: 1)]), context: context).wantsFrequentRefresh)
        #expect(!module.summarize(payload(runs: [run(1, outcome: .success, minutesAgo: 1)]), context: context).wantsFrequentRefresh)
    }

    @Test("REST-Runs nur für aktive oder auffällige Repos mit Workflows")
    func supplementaryRule() {
        let module = ActionsModule(now: { t0 })
        let recent = RepoMeta.fixture(id: "R", name: "o/r", pushedAt: t0.addingTimeInterval(-86_400))
        let dormant = RepoMeta.fixture(id: "R", name: "o/r", pushedAt: t0.addingTimeInterval(-30 * 86_400))
        let request = module.supplementaryRequests(for: recent, payload: payload(runs: []))
        #expect(request.map(\.path) == ["/repos/o/r/actions/runs"])
        #expect(module.supplementaryRequests(for: dormant, payload: payload(runs: [])).isEmpty)
        #expect(!module.supplementaryRequests(for: dormant, payload: payload(head: .failure, runs: [])).isEmpty)
        #expect(module.supplementaryRequests(for: recent, payload: payload(runs: [], workflows: 0)).isEmpty)
    }

    @Test("REST-Antwort wird gelesen; ohne Antwort bleiben die alten Runs")
    func mergeRuns() throws {
        let module = ActionsModule(now: { t0 })
        let body = #"""
        {"total_count":1,"workflow_runs":[{"id":42,"name":"CI","run_number":7,"run_attempt":2,"status":"completed",
          "conclusion":"failure","head_branch":"feat/x","event":"pull_request","actor":{"login":"alice"},
          "run_started_at":"2026-11-20T10:00:00Z","created_at":"2026-11-20T09:59:00Z","updated_at":"2026-11-20T10:03:00Z",
          "html_url":"https://github.com/o/r/actions/runs/42","pull_requests":[{"number":12}]}]}
        """#
        let request = SupplementaryRequest(key: "runs", path: "/repos/o/r/actions/runs")
        let fresh = try module.merge(
            payload(runs: []),
            with: [SupplementaryResponse(request: request, result: .success(Data(body.utf8)), isFromCache: false)],
            previous: nil
        )
        let parsed = try #require(fresh.recentRuns.first)
        #expect(parsed.outcome == .failure)
        #expect(parsed.attempt == 2)
        #expect(parsed.pullRequestNumbers == [12])
        #expect(parsed.duration == 180)
        #expect(fresh.recentRunsFetchedAt == t0)

        let carried = try module.merge(payload(runs: []), with: [], previous: fresh)
        #expect(carried.recentRuns == fresh.recentRuns)
        let failed = try module.merge(
            payload(runs: []),
            with: [SupplementaryResponse(request: request, result: .failure(.http(status: 404)), isFromCache: false)],
            previous: fresh
        )
        #expect(failed.recentRuns == fresh.recentRuns)
    }

    @Test("Änderungen: fehlgeschlagen und wieder grün")
    func changes() {
        let module = ActionsModule(now: { t0 })
        let repo = RepoMeta.fixture(id: "R", name: "o/r")
        let green = payload(runs: [run(1, outcome: .success, minutesAgo: 30)])
        let red = payload(runs: [run(2, outcome: .failure, minutesAgo: 5), run(1, outcome: .success, minutesAgo: 30)])
        #expect(module.changes(from: green, to: red, repository: repo).map(\.kind) == [.custom("workflowFailed")])
        #expect(module.changes(from: red, to: green, repository: repo).map(\.kind) == [.custom("workflowRecovered")])
        #expect(module.changes(from: nil, to: red, repository: repo).isEmpty)
    }
}
