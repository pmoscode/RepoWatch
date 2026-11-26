import Foundation
import Testing
import TestSupport
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

@Suite("GraphQL-Anfrage")
struct GraphQLRequestTests {
    @Test("Sendet POST mit Token, Operation und Variablen")
    func sendsRequest() async throws {
        let seen = Locked<URLRequest?>(nil)
        let (session, baseURL) = MockURLProtocol.makeSession { request in
            seen.withLock { $0 = request }
            return (.make(200, for: request), Data(#"{"data":{"viewer":{"login":"octo"}}}"#.utf8))
        }
        let transport = HTTPTransport(tokenProvider: StaticTokenProvider("t0ken"), session: session)
        let client = GraphQLClient(transport: transport, endpoint: baseURL.appending(path: "graphql"))

        #expect(try await client.viewerLogin() == "octo")

        let request = try #require(seen.value)
        #expect(request.httpMethod == "POST")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "bearer t0ken")
        let body = try #require(request.bodyData)
        let json = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(json["operationName"] as? String == "Viewer")
    }
}
