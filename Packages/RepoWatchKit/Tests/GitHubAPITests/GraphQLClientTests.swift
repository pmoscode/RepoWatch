import Foundation
import Testing
@testable import GitHubAPI

@Suite("GraphQL-Antworten")
struct GraphQLDecodingTests {
    private struct Viewer: Decodable, Sendable {
        struct Inner: Decodable, Sendable { let login: String }
        let viewer: Inner
    }

    @Test("Daten ohne Fehler")
    func decodesData() throws {
        let body = Data(#"{"data":{"viewer":{"login":"octo"}}}"#.utf8)
        let result: GraphQLResult<Viewer> = try GraphQLClient.decode(body)
        #expect(result.data.viewer.login == "octo")
        #expect(result.partialErrors.isEmpty)
    }

    @Test("Teilfehler werden mit den Daten geliefert")
    func keepsPartialErrors() throws {
        let body = Data(#"""
        {"data":{"viewer":{"login":"octo"}},
         "errors":[{"type":"FORBIDDEN","message":"Resource protected","path":["viewer","repositories","nodes",3]}]}
        """#.utf8)
        let result: GraphQLResult<Viewer> = try GraphQLClient.decode(body)
        #expect(result.partialErrors.count == 1)
        #expect(result.partialErrors.first?.path == ["viewer", "repositories", "nodes", "3"])
    }

    @Test("Ohne Daten wird der Fehler geworfen")
    func throwsWithoutData() {
        let body = Data(#"{"data":null,"errors":[{"message":"Something went wrong"}]}"#.utf8)
        #expect(throws: GitHubAPIError.self) {
            let _: GraphQLResult<Viewer> = try GraphQLClient.decode(body)
        }
    }

    @Test("RATE_LIMITED wird erkannt")
    func detectsRateLimit() {
        let body = Data(#"{"errors":[{"type":"RATE_LIMITED","message":"API rate limit exceeded"}]}"#.utf8)
        #expect(throws: GitHubAPIError.rateLimited(resetAt: nil)) {
            let _: GraphQLResult<Viewer> = try GraphQLClient.decode(body)
        }
    }
}

@Suite("HTTP-Status")
struct HTTPStatusTests {
    private func response(_ status: Int, headers: [String: String] = [:]) -> HTTPURLResponse {
        HTTPURLResponse(url: GraphQLClient.defaultEndpoint, statusCode: status, httpVersion: nil, headerFields: headers)!
    }

    @Test func okPasses() throws {
        try GraphQLClient.check(response(200))
    }

    @Test func unauthorized() {
        #expect(throws: GitHubAPIError.unauthorized) { try GraphQLClient.check(response(401)) }
    }

    @Test("403 mit leerem Kontingent ist ein Rate-Limit mit Reset-Zeit")
    func primaryRateLimit() {
        let reset = Date(timeIntervalSince1970: 1_800_000_000)
        #expect(throws: GitHubAPIError.rateLimited(resetAt: reset)) {
            try GraphQLClient.check(response(403, headers: [
                "x-ratelimit-remaining": "0",
                "x-ratelimit-reset": "1800000000",
            ]))
        }
    }

    @Test("403 ohne Limit-Hinweis bleibt ein HTTP-Fehler")
    func plainForbidden() {
        #expect(throws: GitHubAPIError.http(status: 403)) {
            try GraphQLClient.check(response(403, headers: ["x-ratelimit-remaining": "4000"]))
        }
    }
}
