import Domain
import Foundation
import GitHubAPI
import Testing
@testable import Sync

/// Fixtures stammen aus echten Antworten (Phase-0-Spike) und sind anonymisiert.
enum Fixture {
    static func data(_ name: String) throws -> Data {
        let url = try #require(Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures"))
        return try Data(contentsOf: url)
    }
}

@Suite("Bestandsabfrage")
struct InventoryDecodingTests {
    private func decodePage() throws -> InventoryResponse {
        let result: GraphQLResult<InventoryResponse> = try GraphQLClient.decode(try Fixture.data("inventory-page"))
        #expect(result.partialErrors.isEmpty)
        return result.data
    }

    @Test("Echte Antwort wird vollständig dekodiert")
    func decodesFixture() throws {
        let page = try decodePage()
        #expect(page.viewer.login == "viewer")
        #expect(page.viewer.repositories.nodes.count == 6)
        #expect(page.viewer.repositories.pageInfo.hasNextPage == false)
        #expect(page.rateLimit?.cost == 1)
    }

    @Test("Abbildung auf RepoMeta übernimmt Zähler und Flags")
    func mapsToRepoMeta() throws {
        let repos = try decodePage().viewer.repositories.nodes.map(\.repoMeta)
        let archived = try #require(repos.first { $0.isArchived })
        #expect(archived.nameWithOwner == "owner-1/repo-1")
        #expect(archived.owner == "owner-1")
        #expect(archived.name == "repo-1")
        #expect(archived.openIssueCount == 1)
        #expect(archived.openPullRequestCount == 10)
        #expect(repos.contains { $0.isFork })
    }

    @Test("pushedAt: null wird als nil dekodiert")
    func nullPushDateDecodes() throws {
        // In den echten Daten kam der Fall nicht vor; das Schema erlaubt ihn aber.
        var json = try #require(try JSONSerialization.jsonObject(with: try Fixture.data("inventory-page")) as? [String: Any])
        var data = try #require(json["data"] as? [String: Any])
        var viewer = try #require(data["viewer"] as? [String: Any])
        var repositories = try #require(viewer["repositories"] as? [String: Any])
        var nodes = try #require(repositories["nodes"] as? [[String: Any]])
        nodes[0]["pushedAt"] = NSNull()
        repositories["nodes"] = nodes
        viewer["repositories"] = repositories
        data["viewer"] = viewer
        json["data"] = data

        let result: GraphQLResult<InventoryResponse> = try GraphQLClient.decode(
            try JSONSerialization.data(withJSONObject: json)
        )
        #expect(result.data.viewer.repositories.nodes[0].repoMeta.pushedAt == nil)
    }

    @Test("Summen im Snapshot")
    func snapshotTotals() throws {
        let repos = try decodePage().viewer.repositories.nodes.map(\.repoMeta)
        let snapshot = InventorySnapshot(
            viewerLogin: "viewer", repositories: repos, fetchedAt: .now,
            totalCost: 1, pageCount: 1, rateLimit: nil
        )
        #expect(snapshot.totalOpenIssues == repos.map(\.openIssueCount).reduce(0, +))
        #expect(snapshot.totalOpenPullRequests == repos.map(\.openPullRequestCount).reduce(0, +))
    }
}

@Suite("Detail-Fixture (für Phase 2/3)")
struct DetailFixtureTests {
    @Test("Enthält die im Spike gesuchten Fälle")
    func containsSpikeCases() throws {
        let json = try JSONSerialization.jsonObject(with: try Fixture.data("detail-batch")) as? [String: Any]
        let nodes = try #require((json?["data"] as? [String: Any])?["nodes"] as? [Any])
        #expect(nodes.count == 6)
        let text = String(decoding: try Fixture.data("detail-batch"), as: UTF8.self)
        #expect(text.contains(#""__typename": "Bot""#))
        #expect(text.contains(#""login": "renovate""#))
        #expect(text.contains(#""login": "dependabot""#))
        #expect(text.contains(#""__typename": "User""#))
        #expect(text.contains(#""state": "FAILURE""#))
    }
}
