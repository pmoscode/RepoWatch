import Foundation

/// Kleiner GitHub-Simulator für Sync-Tests: beantwortet die Bestandsabfrage, die Detail-Abfrage
/// (Feld `m_count_issues` des `CountModule`) und `GET /repos/{name}/extra` mit ETag.
public final class FakeGitHub: Sendable {
    public struct Repo: Sendable {
        public var id: String
        public var name: String
        public var isArchived: Bool
        public var isFork: Bool
        public var pushedAt: Date
        public var updatedAt: Date
        public var openIssues: Int

        public init(id: String, name: String, isArchived: Bool = false, isFork: Bool = false,
                    pushedAt: Date = Date(timeIntervalSince1970: 1_800_000_000),
                    updatedAt: Date = Date(timeIntervalSince1970: 1_800_000_000), openIssues: Int = 0) {
            self.id = id
            self.name = name
            self.isArchived = isArchived
            self.isFork = isFork
            self.pushedAt = pushedAt
            self.updatedAt = updatedAt
            self.openIssues = openIssues
        }
    }

    public struct State: Sendable {
        public var repos: [Repo]
        /// Diese Repos liefert die Detail-Abfrage als `null` mit Teilfehler.
        public var unreadableIDs: Set<String> = []
        /// Pakete mit mehr Repos werden mit HTTP 502 abgelehnt (simuliert das Zeitlimit).
        public var maxBatchSize: Int?
        public var inventoryStatus = 200
        public var extraValue = "eins"
        public var extraETag = #"W/"v1""#
        /// Größe jedes Detail-Pakets, auch der abgelehnten.
        public var detailBatchSizes: [Int] = []
        public var inventoryRequests = 0
        public var restStatuses: [Int] = []
    }

    public let state: Locked<State>
    public let session: URLSession
    public let baseURL: URL

    public init(repos: [Repo]) {
        let state = Locked(State(repos: repos))
        self.state = state
        (session, baseURL) = MockURLProtocol.makeSession { request in
            try FakeGitHub.handle(request, state: state)
        }
    }

    public var graphQLEndpoint: URL { baseURL.appending(path: "graphql") }

    public func update(_ body: (inout State) -> Void) {
        state.withLock { body(&$0) }
    }

    private static func handle(_ request: URLRequest, state: Locked<State>) throws -> (HTTPURLResponse, Data) {
        let path = request.url?.path() ?? ""
        if path == "/graphql" {
            let body = try JSONSerialization.jsonObject(with: request.bodyData ?? Data()) as? [String: Any] ?? [:]
            switch body["operationName"] as? String {
            case "Inventory":
                return inventory(request, state: state)
            case "RepositoryDetails":
                let ids = (body["variables"] as? [String: Any])?["ids"] as? [String] ?? []
                return details(request, ids: ids, state: state)
            default:
                return (.make(400, for: request), Data())
            }
        }
        if path.hasSuffix("/extra") {
            return extra(request, state: state)
        }
        return (.make(404, for: request), Data())
    }

    private static func iso(_ date: Date) -> String { date.formatted(.iso8601) }

    private static func inventory(_ request: URLRequest, state: Locked<State>) -> (HTTPURLResponse, Data) {
        let snapshot = state.withLock { current -> State in
            current.inventoryRequests += 1
            return current
        }
        guard snapshot.inventoryStatus == 200 else {
            return (.make(snapshot.inventoryStatus, for: request), Data())
        }
        let nodes: [[String: Any]] = snapshot.repos.map { repo in
            [
                "id": repo.id, "nameWithOwner": repo.name, "url": "https://github.com/\(repo.name)",
                "isPrivate": false, "isFork": repo.isFork, "isArchived": repo.isArchived,
                "pushedAt": iso(repo.pushedAt), "updatedAt": iso(repo.updatedAt),
                "issues": ["totalCount": repo.openIssues], "pullRequests": ["totalCount": 0],
            ]
        }
        let json: [String: Any] = ["data": [
            "viewer": ["login": "viewer", "repositories": [
                "totalCount": nodes.count,
                "pageInfo": ["hasNextPage": false, "endCursor": NSNull()],
                "nodes": nodes,
            ]],
            "rateLimit": ["limit": 5000, "cost": 1, "remaining": 4999, "resetAt": "2030-01-01T00:00:00Z"],
        ]]
        return (.make(200, for: request), try! JSONSerialization.data(withJSONObject: json))
    }

    private static func details(_ request: URLRequest, ids: [String], state: Locked<State>) -> (HTTPURLResponse, Data) {
        let snapshot = state.withLock { current -> State in
            current.detailBatchSizes.append(ids.count)
            return current
        }
        if let max = snapshot.maxBatchSize, ids.count > max {
            return (.make(502, for: request), Data("<html>502 Bad Gateway</html>".utf8))
        }
        var errors: [[String: Any]] = []
        let nodes: [Any] = ids.enumerated().map { index, id in
            guard !snapshot.unreadableIDs.contains(id), let repo = snapshot.repos.first(where: { $0.id == id }) else {
                errors.append(["type": "FORBIDDEN", "message": "Resource not accessible", "path": ["nodes", index]])
                return NSNull()
            }
            return ["id": id, "m_count_issues": ["totalCount": repo.openIssues]]
        }
        var json: [String: Any] = ["data": [
            "nodes": nodes,
            "rateLimit": ["limit": 5000, "cost": 1, "remaining": 4990, "resetAt": "2030-01-01T00:00:00Z"],
        ]]
        if !errors.isEmpty { json["errors"] = errors }
        return (.make(200, for: request), try! JSONSerialization.data(withJSONObject: json))
    }

    private static func extra(_ request: URLRequest, state: Locked<State>) -> (HTTPURLResponse, Data) {
        let snapshot = state.value
        if request.value(forHTTPHeaderField: "If-None-Match") == snapshot.extraETag {
            state.withLock { $0.restStatuses.append(304) }
            return (.make(304, for: request), Data())
        }
        state.withLock { $0.restStatuses.append(200) }
        let body = try! JSONSerialization.data(withJSONObject: ["value": snapshot.extraValue])
        return (.make(200, for: request, headers: ["ETag": snapshot.extraETag]), body)
    }
}
