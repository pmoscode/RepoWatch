import Foundation

public struct RESTResponse<Value: Sendable>: Sendable {
    public let value: Value
    /// `true`, wenn GitHub mit `304 Not Modified` geantwortet hat. Solche Antworten
    /// zählen nicht aufs Kontingent (im Spike bestätigt, Konzept 4.3).
    public let isFromCache: Bool
    /// Nächste Seite laut `Link`-Header.
    public let nextPage: URL?
}

/// REST-Zugriff mit ETag-Cache (Konzept 4.1). Nur für das, was GraphQL nicht liefert.
public actor RESTClient {
    public static let defaultBaseURL = URL(string: "https://api.github.com")!

    private struct CachedBody {
        let etag: String
        let body: Data
    }

    private let transport: HTTPTransport
    private let baseURL: URL
    private let maxCacheEntries: Int
    private var cache: [URL: CachedBody] = [:]
    private var cacheOrder: [URL] = []

    private let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    public init(transport: HTTPTransport, baseURL: URL = RESTClient.defaultBaseURL, maxCacheEntries: Int = 500) {
        self.transport = transport
        self.baseURL = baseURL
        self.maxCacheEntries = maxCacheEntries
    }

    /// `GET` auf einen Pfad wie `/repos/{owner}/{repo}/actions/runs`.
    public func get<Value: Decodable & Sendable>(
        _ path: String,
        query: [URLQueryItem] = [],
        as type: Value.Type = Value.self
    ) async throws -> RESTResponse<Value> {
        try await get(url: url(for: path, query: query), as: type)
    }

    /// `GET` auf eine vollständige URL, z. B. `nextPage` einer vorherigen Antwort.
    public func get<Value: Decodable & Sendable>(
        url: URL,
        as type: Value.Type = Value.self
    ) async throws -> RESTResponse<Value> {
        var request = URLRequest(url: url)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        let cached = cache[url]
        if let cached {
            request.setValue(cached.etag, forHTTPHeaderField: "If-None-Match")
        }

        let (data, response) = try await transport.send(request)

        let body: Data
        let isFromCache: Bool
        switch response.statusCode {
        case 304:
            guard let cached else { throw GitHubAPIError.http(status: 304) }
            body = cached.body
            isFromCache = true
        case 202:
            throw GitHubAPIError.pending
        default:
            body = data
            isFromCache = false
            if let etag = response.value(forHTTPHeaderField: "etag") {
                store(CachedBody(etag: etag, body: data), for: url)
            }
        }

        let value: Value
        do {
            value = try decoder.decode(Value.self, from: body)
        } catch {
            throw GitHubAPIError.decoding(String(describing: error))
        }
        return RESTResponse(
            value: value,
            isFromCache: isFromCache,
            nextPage: Self.nextPage(fromLinkHeader: response.value(forHTTPHeaderField: "link"))
        )
    }

    /// Leert den Cache, z. B. beim Abmelden.
    public func clearCache() {
        cache.removeAll()
        cacheOrder.removeAll()
    }

    // MARK: Hilfen

    func url(for path: String, query: [URLQueryItem]) -> URL {
        var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)!
        components.path = (components.path as NSString).appendingPathComponent(path)
        components.queryItems = query.isEmpty ? nil : query
        return components.url!
    }

    private func store(_ entry: CachedBody, for url: URL) {
        if cache.updateValue(entry, forKey: url) == nil {
            cacheOrder.append(url)
        }
        while cacheOrder.count > maxCacheEntries {
            cache.removeValue(forKey: cacheOrder.removeFirst())
        }
    }

    /// Liest `<https://…?page=2>; rel="next", <…>; rel="last"`.
    static func nextPage(fromLinkHeader header: String?) -> URL? {
        guard let header else { return nil }
        for part in header.split(separator: ",") {
            let pieces = part.split(separator: ";").map { $0.trimmingCharacters(in: .whitespaces) }
            guard pieces.count >= 2,
                  pieces.dropFirst().contains(where: { $0 == #"rel="next""# }),
                  pieces[0].hasPrefix("<"), pieces[0].hasSuffix(">")
            else { continue }
            return URL(string: String(pieces[0].dropFirst().dropLast()))
        }
        return nil
    }
}
