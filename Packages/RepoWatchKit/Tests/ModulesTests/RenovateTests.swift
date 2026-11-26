import Domain
import Foundation
import ModuleKit
import Testing
import TestSupport
@testable import PullRequestsModule

private func repository(_ id: String, _ name: String, prs: [(Int, AuthorKind, CIState?)], hasMore: Bool = false) -> RepoSnapshot {
    let items: [[String: Any]] = prs.map { number, kind, ci in
        let kindJSON: [String: Any] = switch kind {
        case .renovate: ["renovate": [:]]
        case .dependabot: ["dependabot": [:]]
        case .me: ["me": [:]]
        case .bot(let name): ["bot": ["name": name]]
        case .human(let login): ["human": ["login": login]]
        }
        var pr: [String: Any] = [
            "number": number, "title": "PR \(number)", "url": "https://github.com/\(name)/pull/\(number)",
            "isDraft": false, "createdAt": Double(number), "updatedAt": Double(number), "branch": "renovate/x",
            "authorLogin": "renovate", "authorKind": kindJSON,
        ]
        pr["ci"] = ci?.rawValue
        return pr
    }
    let json = try! JSONSerialization.data(withJSONObject: ["totalCount": items.count, "items": items, "hasMore": hasMore])
    let payload = try! JSONDecoder().decode(PullRequestsPayload.self, from: json)
    return RepoSnapshot(meta: .fixture(id: id, name: name), payloads: [PullRequestsModule.id: AnyPayload(payload)])
}

@Suite("Renovate-Übersicht")
struct RenovateOverviewTests {
    private let repositories = [
        repository("A", "octocat/alpha", prs: [(1, .renovate, .success), (2, .renovate, .failure), (3, .human(login: "alice"), .failure)]),
        repository("B", "octocat/beta", prs: [(4, .renovate, .success)], hasMore: true),
        repository("C", "octo-org/gamma", prs: [(5, .renovate, .pending), (6, .renovate, nil), (7, .dependabot, .failure)]),
        repository("D", "octo-org/delta", prs: [(8, .human(login: "bob"), .success)]),
    ]

    @Test("Nur Renovate-PRs, nach Org und Repo, Rotes zuerst")
    func grouping() throws {
        let groups = RenovateOverview.groups(from: repositories, viewerLogin: "octocat")
        #expect(groups.map(\.owner) == ["octocat", "octo-org"])

        let mine = try #require(groups.first)
        #expect(mine.counts == RenovateOverview.Counts(total: 3, failing: 1, passing: 2, pending: 0, unchecked: 0))
        #expect(mine.repositories.map(\.repository.name) == ["alpha", "beta"])
        #expect(mine.repositories[0].pullRequests.map(\.number) == [2, 1])
        #expect(mine.repositories[1].isIncomplete)

        let org = try #require(groups.last)
        // delta hat keine Renovate-PRs, Dependabot zählt nicht mit.
        #expect(org.repositories.map(\.repository.name) == ["gamma"])
        #expect(org.counts == RenovateOverview.Counts(total: 2, failing: 0, passing: 0, pending: 1, unchecked: 1))
    }

    @Test("Links: gefilterte PR-Liste je Repo, Suche je Org bzw. eigenem Konto")
    func links() throws {
        let groups = RenovateOverview.groups(from: repositories, viewerLogin: "octocat")
        let repositoryURL = try #require(groups.first?.repositories.first?.pullRequestsURL)
        #expect(repositoryURL.absoluteString == "https://github.com/octocat/alpha/pulls?q=is:pr%20is:open%20author:app/renovate")
        #expect(groups.first?.pullRequestsURL.absoluteString == "https://github.com/pulls?q=is:pr%20is:open%20author:app/renovate%20user:octocat")
        #expect(groups.last?.pullRequestsURL.absoluteString == "https://github.com/pulls?q=is:pr%20is:open%20author:app/renovate%20org:octo-org")
    }

    @Test("Suche filtert PRs; Repos ohne Treffer fallen weg")
    func search() {
        let groups = RenovateOverview.groups(from: repositories, viewerLogin: "octocat") { _, pr in pr.number == 5 }
        #expect(groups.flatMap(\.repositories).map(\.repository.name) == ["gamma"])
    }
}

@Suite("Renovate-Titel")
struct RenovateTitleTests {
    @Test(arguments: [
        ("chore(deps): update dependency express to v5", "express to v5"),
        ("chore(deps): update actions/checkout action to v5", "actions/checkout action to v5"),
        ("fix(deps)!: update module github.com/foo/bar to v2", "module github.com/foo/bar to v2"),
        ("Update dependency typescript to v6", "typescript to v6"),
        ("Update node Docker tag to v24", "node Docker tag to v24"),
        ("Lock file maintenance", "Lock file maintenance"),
        ("Configure Renovate", "Configure Renovate"),
    ])
    func shortTitle(title: String, expected: String) {
        #expect(RenovateOverview.shortTitle(title) == expected)
    }
}
