import Domain
import Foundation

/// Liefert das aktuelle Zugriffstoken. Umsetzungen liegen im Target `Auth`.
public protocol TokenProviding: Sendable {
    func token() async throws -> String
}

/// Festes Token, z. B. um ein eingegebenes PAT vor dem Speichern zu prüfen.
public struct StaticTokenProvider: TokenProviding {
    private let value: String
    public init(_ value: String) { self.value = value }
    public func token() async throws -> String { value }
}

/// Wartet die angegebene Zeit. In Tests wird ein Aufzeichner eingesetzt.
public typealias Sleeper = @Sendable (Duration) async throws -> Void

public struct RetryPolicy: Sendable {
    /// Anzahl Versuche inklusive des ersten.
    public var maxAttempts: Int
    public var baseDelay: Duration
    public var maxDelay: Duration
    /// 502 fehlt absichtlich: GitHub meldet so auch zu schwere GraphQL-Abfragen.
    /// Die `SyncEngine` verkleinert dann das Paket, statt dieselbe Anfrage zu wiederholen.
    public var retryableStatusCodes: Set<Int>

    public init(maxAttempts: Int, baseDelay: Duration, maxDelay: Duration, retryableStatusCodes: Set<Int>) {
        self.maxAttempts = maxAttempts
        self.baseDelay = baseDelay
        self.maxDelay = maxDelay
        self.retryableStatusCodes = retryableStatusCodes
    }

    public static let `default` = RetryPolicy(
        maxAttempts: 3,
        baseDelay: .seconds(1),
        maxDelay: .seconds(60),
        retryableStatusCodes: [500, 503, 504]
    )

    public static let none = RetryPolicy(maxAttempts: 1, baseDelay: .zero, maxDelay: .zero, retryableStatusCodes: [])

    /// Exponentiell: 1 s, 2 s, 4 s … bis `maxDelay`.
    func delay(afterAttempt attempt: Int) -> Duration {
        let factor = 1 << max(0, attempt - 1)
        return min(baseDelay * factor, maxDelay)
    }
}

/// Gemeinsame HTTP-Schicht für GraphQL und REST (Konzept 4.2, Plan Phase 1):
/// Token, Drosselung auf wenige parallele Anfragen, Wiederholungen und Rate-Limit-Stand.
public actor HTTPTransport {
    private let session: URLSession
    private let tokenProvider: any TokenProviding
    private let retryPolicy: RetryPolicy
    private let sleep: Sleeper
    private let now: @Sendable () -> Date
    private let maxConcurrentRequests: Int

    private var runningRequests = 0
    private var waiting: [CheckedContinuation<Void, Never>] = []

    /// Letzter bekannter Stand je Ressource (`graphql`, `core`, …) aus den `x-ratelimit-*`-Headern.
    public private(set) var rateLimits: [String: RateLimitInfo] = [:]

    public init(
        tokenProvider: any TokenProviding,
        session: URLSession = HTTPTransport.makeSession(),
        maxConcurrentRequests: Int = 3,
        retryPolicy: RetryPolicy = .default,
        sleep: @escaping Sleeper = { try await Task.sleep(for: $0) },
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.tokenProvider = tokenProvider
        self.session = session
        self.maxConcurrentRequests = max(1, maxConcurrentRequests)
        self.retryPolicy = retryPolicy
        self.sleep = sleep
        self.now = now
    }

    /// Eigene Session ohne `URLCache`: Sonst beantwortet URLSession unsere `If-None-Match`-Anfragen
    /// selbst aus dem Cache, und der REST-Client sähe nie ein `304`.
    public static func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 30
        return URLSession(configuration: configuration)
    }

    public func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let resource = Self.resource(for: request)
        if let limit = rateLimits[resource], limit.remaining == 0, limit.resetAt > now() {
            throw GitHubAPIError.rateLimited(resetAt: limit.resetAt)
        }

        var request = request
        let token: String
        do {
            token = try await tokenProvider.token()
        } catch {
            throw GitHubAPIError.missingToken
        }
        request.setValue("bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("RepoWatch", forHTTPHeaderField: "User-Agent")

        var attempt = 0
        while true {
            attempt += 1
            try Task.checkCancellation()
            let hasAttemptsLeft = attempt < retryPolicy.maxAttempts

            let data: Data
            let response: HTTPURLResponse
            do {
                (data, response) = try await perform(request)
            } catch let error as URLError {
                switch error.code {
                case .notConnectedToInternet, .dataNotAllowed:
                    throw GitHubAPIError.offline
                case .timedOut, .networkConnectionLost, .cannotConnectToHost:
                    // (Ein `where` gälte hier nur für das letzte Muster, daher `guard`.)
                    guard hasAttemptsLeft else {
                        throw GitHubAPIError.transport(error.localizedDescription)
                    }
                    try await sleep(retryPolicy.delay(afterAttempt: attempt))
                    continue
                case .cancelled:
                    throw CancellationError()
                default:
                    throw GitHubAPIError.transport(error.localizedDescription)
                }
            }

            if let (resource, info) = Self.rateLimit(from: response) {
                rateLimits[resource] = info
            }

            switch response.statusCode {
            case 200..<300, 304:
                return (data, response)

            case 401:
                throw GitHubAPIError.unauthorized

            case 403, 429:
                if response.value(forHTTPHeaderField: "x-ratelimit-remaining") == "0" {
                    // Primäres Limit: Warten bis zum Reset lohnt sich nicht, die App zeigt den Stand an.
                    throw GitHubAPIError.rateLimited(resetAt: Self.resetDate(from: response))
                }
                if let retryAfter = response.value(forHTTPHeaderField: "retry-after").flatMap(Int.init) {
                    // Sekundäres Limit: GitHub sagt, wie lange wir warten sollen.
                    let wait = Duration.seconds(retryAfter)
                    guard hasAttemptsLeft, wait <= retryPolicy.maxDelay else {
                        throw GitHubAPIError.rateLimited(resetAt: now().addingTimeInterval(TimeInterval(retryAfter)))
                    }
                    try await sleep(wait)
                    continue
                }
                throw GitHubAPIError.http(status: response.statusCode)

            case let status where retryPolicy.retryableStatusCodes.contains(status) && hasAttemptsLeft:
                try await sleep(retryPolicy.delay(afterAttempt: attempt))
                continue

            case 500..<600:
                throw GitHubAPIError.server(status: response.statusCode)

            default:
                throw GitHubAPIError.http(status: response.statusCode)
            }
        }
    }

    // MARK: Drosselung

    /// Führt eine Anfrage aus, wenn ein Platz frei ist. Wartezeiten zwischen Versuchen belegen keinen Platz.
    private func perform(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        await acquire()
        defer { release() }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw GitHubAPIError.transport("Keine HTTP-Antwort")
        }
        return (data, http)
    }

    private func acquire() async {
        if runningRequests < maxConcurrentRequests {
            runningRequests += 1
            return
        }
        await withCheckedContinuation { waiting.append($0) }
        // Der Platz wurde von `release()` direkt übergeben.
    }

    private func release() {
        if waiting.isEmpty {
            runningRequests -= 1
        } else {
            waiting.removeFirst().resume()
        }
    }

    // MARK: Rate-Limit-Header

    static func resource(for request: URLRequest) -> String {
        request.url?.path == "/graphql" ? "graphql" : "core"
    }

    static func resetDate(from response: HTTPURLResponse) -> Date? {
        response.value(forHTTPHeaderField: "x-ratelimit-reset")
            .flatMap(TimeInterval.init)
            .map(Date.init(timeIntervalSince1970:))
    }

    static func rateLimit(from response: HTTPURLResponse) -> (String, RateLimitInfo)? {
        guard
            let limit = response.value(forHTTPHeaderField: "x-ratelimit-limit").flatMap(Int.init),
            let remaining = response.value(forHTTPHeaderField: "x-ratelimit-remaining").flatMap(Int.init),
            let resetAt = resetDate(from: response)
        else { return nil }
        let resource = response.value(forHTTPHeaderField: "x-ratelimit-resource") ?? "core"
        return (resource, RateLimitInfo(limit: limit, remaining: remaining, resetAt: resetAt, cost: nil))
    }
}
