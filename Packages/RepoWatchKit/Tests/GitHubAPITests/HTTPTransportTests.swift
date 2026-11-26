import Foundation
import Testing
import TestSupport
@testable import GitHubAPI

@Suite("HTTP-Transport")
struct HTTPTransportTests {
    /// Transport gegen einen Mock, der die Antworten der Reihe nach liefert.
    private func makeTransport(
        maxConcurrent: Int = 3,
        sleeper: SleepRecorder = SleepRecorder(),
        responses: [@Sendable (URLRequest) throws -> (HTTPURLResponse, Data)]
    ) -> (HTTPTransport, URL, Locked<Int>) {
        let calls = Locked(0)
        let (session, baseURL) = MockURLProtocol.makeSession { request in
            let index = calls.withLock { count -> Int in
                count += 1
                return count - 1
            }
            return try responses[min(index, responses.count - 1)](request)
        }
        let transport = HTTPTransport(
            tokenProvider: StaticTokenProvider("t"),
            session: session,
            maxConcurrentRequests: maxConcurrent,
            sleep: sleeper.sleeper
        )
        return (transport, baseURL, calls)
    }

    private func status(_ code: Int, _ headers: [String: String] = [:]) -> @Sendable (URLRequest) throws -> (HTTPURLResponse, Data) {
        { (.make(code, for: $0, headers: headers), Data("{}".utf8)) }
    }

    @Test("503 wird mit Wartezeit wiederholt")
    func retriesServiceUnavailable() async throws {
        let sleeper = SleepRecorder()
        let (transport, url, calls) = makeTransport(sleeper: sleeper, responses: [status(503), status(200)])
        let (_, response) = try await transport.send(URLRequest(url: url))
        #expect(response.statusCode == 200)
        #expect(calls.value == 2)
        #expect(sleeper.durations == [.seconds(1)])
    }

    @Test("502 wird nicht wiederholt (Signal für zu schwere Abfrage)")
    func badGatewayIsNotRetried() async {
        let (transport, url, calls) = makeTransport(responses: [status(502), status(200)])
        await #expect(throws: GitHubAPIError.server(status: 502)) {
            _ = try await transport.send(URLRequest(url: url))
        }
        #expect(calls.value == 1)
    }

    @Test("Sekundäres Limit: wartet Retry-After ab und versucht erneut")
    func secondaryRateLimit() async throws {
        let sleeper = SleepRecorder()
        let (transport, url, calls) = makeTransport(
            sleeper: sleeper,
            responses: [status(403, ["retry-after": "7", "x-ratelimit-remaining": "4000"]), status(200)]
        )
        _ = try await transport.send(URLRequest(url: url))
        #expect(calls.value == 2)
        #expect(sleeper.durations == [.seconds(7)])
    }

    @Test("Primäres Limit: Fehler mit Reset-Zeit, danach keine Anfrage mehr bis zum Reset")
    func primaryRateLimit() async throws {
        let reset = Date().addingTimeInterval(3600)
        let headers = [
            "x-ratelimit-limit": "5000",
            "x-ratelimit-remaining": "0",
            "x-ratelimit-reset": String(Int(reset.timeIntervalSince1970)),
            "x-ratelimit-resource": "core",
        ]
        let (transport, url, calls) = makeTransport(responses: [status(403, headers)])
        let expectedReset = Date(timeIntervalSince1970: TimeInterval(Int(reset.timeIntervalSince1970)))

        await #expect(throws: GitHubAPIError.rateLimited(resetAt: expectedReset)) {
            _ = try await transport.send(URLRequest(url: url))
        }
        await #expect(throws: GitHubAPIError.rateLimited(resetAt: expectedReset)) {
            _ = try await transport.send(URLRequest(url: url))
        }
        #expect(calls.value == 1)
    }

    @Test("Rate-Limit-Stand wird je Ressource gemerkt")
    func recordsRateLimit() async throws {
        let headers = [
            "x-ratelimit-limit": "5000",
            "x-ratelimit-remaining": "4321",
            "x-ratelimit-reset": "1800000000",
            "x-ratelimit-resource": "graphql",
        ]
        let (transport, url, _) = makeTransport(responses: [status(200, headers)])
        _ = try await transport.send(URLRequest(url: url))
        let info = try #require(await transport.rateLimits["graphql"])
        #expect(info.remaining == 4321)
        #expect(info.limit == 5000)
    }

    @Test func unauthorized() async {
        let (transport, url, _) = makeTransport(responses: [status(401)])
        await #expect(throws: GitHubAPIError.unauthorized) {
            _ = try await transport.send(URLRequest(url: url))
        }
    }

    @Test("Ohne Netz: .offline ohne Wiederholung")
    func offline() async {
        let (transport, url, calls) = makeTransport(responses: [{ _ in throw URLError(.notConnectedToInternet) }])
        await #expect(throws: GitHubAPIError.offline) {
            _ = try await transport.send(URLRequest(url: url))
        }
        #expect(calls.value == 1)
    }

    @Test("Höchstens N Anfragen gleichzeitig")
    func limitsConcurrency() async throws {
        let running = Locked(0)
        let peak = Locked(0)
        let (transport, url, _) = makeTransport(maxConcurrent: 2, responses: [{ request in
            let now = running.withLock { count -> Int in
                count += 1
                return count
            }
            peak.withLock { $0 = max($0, now) }
            Thread.sleep(forTimeInterval: 0.05)
            running.withLock { $0 -= 1 }
            return (.make(200, for: request), Data())
        }])

        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<6 {
                group.addTask { _ = try await transport.send(URLRequest(url: url)) }
            }
            try await group.waitForAll()
        }
        #expect(peak.value <= 2)
        #expect(peak.value >= 1)
    }

    @Test("Wartezeiten wachsen exponentiell bis zur Obergrenze")
    func backoff() {
        let policy = RetryPolicy(maxAttempts: 10, baseDelay: .seconds(1), maxDelay: .seconds(5), retryableStatusCodes: [])
        #expect(policy.delay(afterAttempt: 1) == .seconds(1))
        #expect(policy.delay(afterAttempt: 2) == .seconds(2))
        #expect(policy.delay(afterAttempt: 3) == .seconds(4))
        #expect(policy.delay(afterAttempt: 4) == .seconds(5))
    }
}
