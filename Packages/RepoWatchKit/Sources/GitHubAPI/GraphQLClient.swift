import Domain
import Foundation

/// Liefert das aktuelle Zugriffstoken. Umsetzungen liegen im Target `Auth`.
public protocol TokenProviding: Sendable {
    func token() async throws -> String
}

/// Eine GraphQL-Operation mit ihrem Antworttyp (Inhalt von `data`).
public struct GraphQLOperation<Response: Decodable & Sendable>: Sendable {
    public let name: String
    public let query: String
    public let variables: [String: GraphQLVariable]

    public init(name: String, query: String, variables: [String: GraphQLVariable] = [:]) {
        self.name = name
        self.query = query
        self.variables = variables
    }
}

public enum GraphQLVariable: Encodable, Sendable, Hashable {
    case string(String)
    case int(Int)
    case bool(Bool)
    case strings([String])
    case null

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value): try container.encode(value)
        case .int(let value): try container.encode(value)
        case .bool(let value): try container.encode(value)
        case .strings(let value): try container.encode(value)
        case .null: try container.encodeNil()
        }
    }
}

public struct GraphQLError: Decodable, Sendable, Hashable {
    public let message: String
    public let type: String?
    public let path: [String]?

    private enum CodingKeys: String, CodingKey { case message, type, path }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        message = try container.decode(String.self, forKey: .message)
        type = try container.decodeIfPresent(String.self, forKey: .type)
        // `path` mischt Strings und Indizes; für Meldungen reicht die Textform.
        if var pathContainer = try? container.nestedUnkeyedContainer(forKey: .path) {
            var parts: [String] = []
            while !pathContainer.isAtEnd {
                if let text = try? pathContainer.decode(String.self) {
                    parts.append(text)
                } else if let index = try? pathContainer.decode(Int.self) {
                    parts.append(String(index))
                } else {
                    break
                }
            }
            path = parts
        } else {
            path = nil
        }
    }
}

/// Antwort inklusive eventueller Teilfehler: GraphQL kann `data` und `errors` gleichzeitig liefern.
public struct GraphQLResult<Response: Sendable>: Sendable {
    public let data: Response
    public let partialErrors: [GraphQLError]
}

public enum GitHubAPIError: Error, Sendable, Equatable {
    case missingToken
    case unauthorized
    case rateLimited(resetAt: Date?)
    case http(status: Int)
    case graphQL([GraphQLError])
    case decoding(String)
    case transport(String)
}

extension GitHubAPIError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .missingToken: "Kein GitHub-Token vorhanden."
        case .unauthorized: "GitHub hat das Token abgelehnt."
        case .rateLimited: "GitHub-Kontingent erschöpft."
        case .http(let status): "GitHub antwortete mit HTTP \(status)."
        case .graphQL(let errors): errors.map(\.message).joined(separator: "\n")
        case .decoding(let detail): "Antwort nicht lesbar: \(detail)"
        case .transport(let detail): "Netzwerkfehler: \(detail)"
        }
    }
}

/// Minimaler GraphQL-Client. Ausbau (Backoff, Drosselung) folgt in Phase 1.
public actor GraphQLClient {
    public static let defaultEndpoint = URL(string: "https://api.github.com/graphql")!

    private let endpoint: URL
    private let session: URLSession
    private let tokenProvider: any TokenProviding

    public init(
        endpoint: URL = GraphQLClient.defaultEndpoint,
        session: URLSession = .shared,
        tokenProvider: any TokenProviding
    ) {
        self.endpoint = endpoint
        self.session = session
        self.tokenProvider = tokenProvider
    }

    public func send<Response>(_ operation: GraphQLOperation<Response>) async throws -> GraphQLResult<Response> {
        let token: String
        do {
            token = try await tokenProvider.token()
        } catch {
            throw GitHubAPIError.missingToken
        }

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("RepoWatch", forHTTPHeaderField: "User-Agent")
        request.httpBody = try JSONEncoder().encode(
            RequestBody(query: operation.query, variables: operation.variables, operationName: operation.name)
        )

        let (body, response): (Data, URLResponse)
        do {
            (body, response) = try await session.data(for: request)
        } catch {
            throw GitHubAPIError.transport(error.localizedDescription)
        }

        if let http = response as? HTTPURLResponse {
            try Self.check(http)
        }
        return try Self.decode(body)
    }

    /// Dekodiert einen Antwort-Body. Öffentlich, damit Tests Fixtures direkt prüfen können.
    public static func decode<Response: Decodable & Sendable>(_ body: Data) throws -> GraphQLResult<Response> {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let envelope: Envelope<Response>
        do {
            envelope = try decoder.decode(Envelope<Response>.self, from: body)
        } catch {
            throw GitHubAPIError.decoding(String(describing: error))
        }
        let errors = envelope.errors ?? []
        if errors.contains(where: { $0.type == "RATE_LIMITED" }) {
            throw GitHubAPIError.rateLimited(resetAt: nil)
        }
        guard let data = envelope.data else {
            throw GitHubAPIError.graphQL(errors)
        }
        return GraphQLResult(data: data, partialErrors: errors)
    }

    static func check(_ response: HTTPURLResponse) throws {
        switch response.statusCode {
        case 200..<300:
            return
        case 401:
            throw GitHubAPIError.unauthorized
        case 403, 429:
            let remaining = response.value(forHTTPHeaderField: "x-ratelimit-remaining")
            let isLimited = remaining == "0" || response.value(forHTTPHeaderField: "retry-after") != nil
            if isLimited {
                let reset = response.value(forHTTPHeaderField: "x-ratelimit-reset")
                    .flatMap(TimeInterval.init)
                    .map(Date.init(timeIntervalSince1970:))
                throw GitHubAPIError.rateLimited(resetAt: reset)
            }
            throw GitHubAPIError.http(status: response.statusCode)
        default:
            throw GitHubAPIError.http(status: response.statusCode)
        }
    }

    private struct RequestBody: Encodable {
        let query: String
        let variables: [String: GraphQLVariable]
        let operationName: String
    }

    private struct Envelope<D: Decodable>: Decodable {
        let data: D?
        let errors: [GraphQLError]?
    }
}
