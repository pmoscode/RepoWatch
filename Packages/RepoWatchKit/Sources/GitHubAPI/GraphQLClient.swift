import Domain
import Foundation

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

/// GraphQL über die gemeinsame `HTTPTransport`-Schicht.
public struct GraphQLClient: Sendable {
    public static let defaultEndpoint = URL(string: "https://api.github.com/graphql")!

    public let transport: HTTPTransport
    private let endpoint: URL

    public init(transport: HTTPTransport, endpoint: URL = GraphQLClient.defaultEndpoint) {
        self.transport = transport
        self.endpoint = endpoint
    }

    public func send<Response>(_ operation: GraphQLOperation<Response>) async throws -> GraphQLResult<Response> {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(
            RequestBody(query: operation.query, variables: operation.variables, operationName: operation.name)
        )
        let (body, _) = try await transport.send(request)
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

// MARK: - Angemeldeter Benutzer

public struct ViewerResponse: Decodable, Sendable {
    public struct Viewer: Decodable, Sendable {
        public let login: String
    }
    public let viewer: Viewer
}

extension GraphQLClient {
    /// Login des Token-Inhabers; prüft dabei gleichzeitig, ob das Token gültig ist.
    public func viewerLogin() async throws -> String {
        let operation = GraphQLOperation<ViewerResponse>(name: "Viewer", query: "query Viewer { viewer { login } }")
        return try await send(operation).data.viewer.login
    }
}
