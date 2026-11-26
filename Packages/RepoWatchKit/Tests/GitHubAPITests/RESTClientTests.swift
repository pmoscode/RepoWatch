import Foundation
import Testing
import TestSupport
@testable import GitHubAPI

@Suite("REST-Client")
struct RESTClientTests {
    private struct Runs: Decodable, Sendable {
        let totalCount: Int
    }

    @Test("ETag: zweite Anfrage schickt If-None-Match und nutzt bei 304 den Cache")
    func etagCaching() async throws {
        let requests = Locked<[URLRequest]>([])
        let (session, baseURL) = MockURLProtocol.makeSession { request in
            let isFirst = requests.withLock { list -> Bool in
                list.append(request)
                return list.count == 1
            }
            if isFirst {
                return (.make(200, for: request, headers: ["ETag": #"W/"abc""#]), Data(#"{"total_count":3}"#.utf8))
            }
            return (.make(304, for: request), Data())
        }
        let client = RESTClient(
            transport: HTTPTransport(tokenProvider: StaticTokenProvider("t"), session: session),
            baseURL: baseURL
        )

        let first = try await client.get("/repos/o/r/actions/runs", query: [.init(name: "per_page", value: "30")], as: Runs.self)
        let second = try await client.get("/repos/o/r/actions/runs", query: [.init(name: "per_page", value: "30")], as: Runs.self)

        #expect(first.value.totalCount == 3)
        #expect(first.isFromCache == false)
        #expect(second.value.totalCount == 3)
        #expect(second.isFromCache == true)
        let sent = requests.value
        #expect(sent.count == 2)
        #expect(sent[0].value(forHTTPHeaderField: "If-None-Match") == nil)
        #expect(sent[1].value(forHTTPHeaderField: "If-None-Match") == #"W/"abc""#)
        #expect(sent[1].url?.query() == "per_page=30")
    }

    @Test("202 Accepted → .pending")
    func pending() async {
        let (session, baseURL) = MockURLProtocol.makeSession { (.make(202, for: $0), Data("{}".utf8)) }
        let client = RESTClient(
            transport: HTTPTransport(tokenProvider: StaticTokenProvider("t"), session: session),
            baseURL: baseURL
        )
        await #expect(throws: GitHubAPIError.pending) {
            _ = try await client.get("/repos/o/r/stats/participation", as: Runs.self)
        }
    }

    @Test("Link-Header: nächste Seite wird erkannt")
    func linkHeader() {
        let header = #"<https://api.github.com/x?page=2>; rel="next", <https://api.github.com/x?page=5>; rel="last""#
        #expect(RESTClient.nextPage(fromLinkHeader: header)?.absoluteString == "https://api.github.com/x?page=2")
        #expect(RESTClient.nextPage(fromLinkHeader: #"<https://api.github.com/x?page=1>; rel="prev""#) == nil)
        #expect(RESTClient.nextPage(fromLinkHeader: nil) == nil)
    }
}
