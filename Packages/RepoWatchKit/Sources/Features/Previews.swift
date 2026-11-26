#if DEBUG
import ActionsModule
import ActivityModule
import Auth
import Domain
import Foundation
import IssuesModule
import ModuleKit
import Persistence
import PullRequestsModule
import SwiftUI

/// Beispieldaten für SwiftUI-Previews. Payloads werden über ihr Codable-Format gebaut,
/// damit die Module dafür keine zusätzliche öffentliche Schnittstelle brauchen.
@MainActor
enum PreviewData {
    static let now = Date()

    private static func ago(_ hours: Double) -> Double {
        now.addingTimeInterval(-hours * 3600).timeIntervalSinceReferenceDate
    }

    private static func decode<P: ModulePayload>(_ type: P.Type, _ json: [String: Any]) -> AnyPayload {
        let data = try! JSONSerialization.data(withJSONObject: json)
        return AnyPayload(try! JSONDecoder().decode(type, from: data))
    }

    private static func repository(
        _ id: String, _ name: String, pushedHoursAgo: Double, isPrivate: Bool = false,
        issues: [[String: Any]], prs: [[String: Any]], commits7d: Int, score: Int,
        headStatus: String?, runs: [[String: Any]], workflows: Int
    ) -> RepoSnapshot {
        let meta = RepoMeta(
            id: id, nameWithOwner: name, url: URL(string: "https://github.com/\(name)")!, isPrivate: isPrivate,
            isFork: false, isArchived: false, pushedAt: Date(timeIntervalSinceReferenceDate: ago(pushedHoursAgo)),
            updatedAt: Date(timeIntervalSinceReferenceDate: ago(pushedHoursAgo)),
            openIssueCount: issues.count, openPullRequestCount: prs.count
        )
        var actions: [String: Any] = [
            "workflowFileCount": workflows, "defaultBranch": "main", "headRuns": [], "recentRuns": runs,
        ]
        actions["headStatus"] = headStatus
        let payloads: [ModuleID: AnyPayload] = [
            IssuesModule.id: decode(IssuesPayload.self, ["totalCount": issues.count, "items": issues, "hasMore": false]),
            PullRequestsModule.id: decode(PullRequestsPayload.self, ["totalCount": prs.count, "items": prs, "hasMore": false]),
            ActivityModule.id: decode(ActivityPayload.self, [
                "commits7d": commits7d, "commits30d": commits7d * 3, "issuesOpened7d": 1, "issuesClosed7d": 0,
                "prsOpened7d": prs.count, "prsMerged7d": 1, "lastPush": ago(pushedHoursAgo), "score": score,
            ]),
            ActionsModule.id: decode(ActionsPayload.self, actions),
        ]
        let alerting = headStatus == "failure"
        return RepoSnapshot(
            meta: meta, payloads: payloads,
            summaries: [
                ActivityModule.id: ModuleSummary(counts: ["score": score]),
                ActionsModule.id: ModuleSummary(counts: ["alerting": alerting ? 1 : 0], needsAttention: alerting),
                PullRequestsModule.id: ModuleSummary(counts: ["human": prs.count]),
            ],
            detailsFetchedAt: now
        )
    }

    private static func issue(_ number: Int, _ title: String, hours: Double, labels: [(String, String)] = []) -> [String: Any] {
        [
            "number": number, "title": title, "url": "https://github.com/demo/app/issues/\(number)",
            "createdAt": ago(hours * 2), "updatedAt": ago(hours), "author": "alice", "commentCount": 2,
            "labels": labels.map { ["name": $0.0, "color": $0.1] },
        ]
    }

    private static func pr(_ number: Int, _ title: String, kind: [String: Any], branch: String, ci: String?, hours: Double) -> [String: Any] {
        var pr: [String: Any] = [
            "number": number, "title": title, "url": "https://github.com/demo/app/pull/\(number)", "isDraft": false,
            "createdAt": ago(hours * 2), "updatedAt": ago(hours), "branch": branch, "authorLogin": "alice", "authorKind": kind,
        ]
        pr["ci"] = ci
        return pr
    }

    private static func run(_ id: Int, _ workflow: String, outcome: String, hours: Double, branch: String = "main") -> [String: Any] {
        [
            "id": id, "workflowName": workflow, "runNumber": id, "attempt": 1, "outcome": outcome, "branch": branch,
            "event": "push", "actor": "alice", "startedAt": ago(hours), "updatedAt": ago(hours - 0.05),
            "url": "https://github.com/demo/app/actions/runs/\(id)", "pullRequestNumbers": [],
        ]
    }

    static let state = SyncState(
        viewerLogin: "octocat",
        inventoryFetchedAt: now,
        lastSyncAt: now.addingTimeInterval(-90),
        rateLimit: RateLimitInfo(limit: 5000, remaining: 4812, resetAt: now.addingTimeInterval(1800), cost: 1),
        repositories: [
            repository("R1", "octocat/repowatch", pushedHoursAgo: 2,
                       issues: [issue(12, "Panel merkt sich die Scroll-Position nicht", hours: 3, labels: [("bug", "d73a4a")])],
                       prs: [pr(14, "Benachrichtigungen bei fehlgeschlagenen Workflows", kind: ["human": ["login": "alice"]],
                                branch: "feat/notifications", ci: "success", hours: 1),
                             pr(15, "Update dependency swift-format to v6", kind: ["renovate": [:]],
                                branch: "renovate/swift-format-6.x", ci: "failure", hours: 5)],
                       commits7d: 12, score: 48, headStatus: "success",
                       runs: [run(101, "CI", outcome: "success", hours: 2)], workflows: 2),
            repository("R2", "octocat/homelab", pushedHoursAgo: 26, isPrivate: true,
                       issues: [], prs: [pr(7, "Update traefik to v3.4", kind: ["renovate": [:]], branch: "renovate/traefik-3.x", ci: "success", hours: 8)],
                       commits7d: 3, score: 9, headStatus: "failure",
                       runs: [run(202, "deploy", outcome: "failure", hours: 20), run(201, "deploy", outcome: "success", hours: 50)], workflows: 1),
            repository("R4", "octo-org/website", pushedHoursAgo: 5,
                       issues: [issue(41, "Dunkelmodus für die Startseite", hours: 30, labels: [("design", "c5def5")]),
                                issue(40, "Links im Footer veraltet", hours: 70, labels: [("bug", "d73a4a")])],
                       prs: [pr(88, "Update dependency astro to v6", kind: ["renovate": [:]], branch: "renovate/astro-6.x", ci: "failure", hours: 4),
                             pr(87, "Update dependency typescript to v6", kind: ["renovate": [:]], branch: "renovate/typescript-6.x", ci: "success", hours: 20),
                             pr(86, "Bump actions/checkout from 4 to 5", kind: ["dependabot": [:]], branch: "dependabot/github_actions/checkout-5", ci: "success", hours: 40)],
                       commits7d: 7, score: 27, headStatus: "success",
                       runs: [run(401, "Build", outcome: "success", hours: 5), run(402, "Build", outcome: "failure", hours: 4, branch: "renovate/astro-6.x")],
                       workflows: 2),
            repository("R5", "octocat/notes", pushedHoursAgo: 24 * 40,
                       issues: [], prs: [], commits7d: 0, score: 0, headStatus: "success",
                       runs: [run(501, "Lint", outcome: "success", hours: 24 * 40)], workflows: 1),
            repository("R3", "octo-org/dotfiles", pushedHoursAgo: 24 * 9,
                       issues: [issue(3, "Zsh-Startzeit messen", hours: 24 * 9, labels: [("enhancement", "a2eeef")])],
                       prs: [], commits7d: 0, score: 0, headStatus: nil, runs: [], workflows: 0),
        ]
    )

    static func model(signedIn: Bool = true) -> AppModel {
        let model = AppModel(configuration: AppConfiguration(
            oauthClientID: "preview", tokenStore: InMemoryTokenStore(),
            seenStateStore: InMemorySeenStateStore(), settingsStore: InMemorySettingsStore()
        ))
        if signedIn { model.loadPreview(state) }
        return model
    }
}

extension AppModel {
    /// Nur Debug: Demo-Daten statt echter Repos anzeigen (Screenshots für die README, `--demo`).
    public func loadDemo() {
        loadPreview(PreviewData.state)
    }
}

extension AppConfiguration {
    /// Nur Debug: alles im Arbeitsspeicher, kein Schlüsselbund, kein Cache auf der Platte (`--demo`).
    public static func demo() -> AppConfiguration {
        AppConfiguration(
            oauthClientID: nil, tokenStore: InMemoryTokenStore(),
            seenStateStore: InMemorySeenStateStore(), settingsStore: InMemorySettingsStore()
        )
    }
}

#Preview("Panel – Übersicht") {
    PanelRootView(model: PreviewData.model(), onQuit: {}, onOpenSettings: {})
}

#Preview("Panel – Anmeldung") {
    PanelRootView(model: PreviewData.model(signedIn: false), onQuit: {}, onOpenSettings: {})
}

#Preview("Einstellungen") {
    SettingsView(model: PreviewData.model())
}
#endif
