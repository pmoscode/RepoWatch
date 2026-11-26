import Domain
import Foundation
import GitHubAPI

/// Variablen, die die Detail-Abfrage bereitstellt. Module deklarieren, welche sie nutzen.
public enum QueryVariable: String, CaseIterable, Sendable, Hashable, Comparable {
    /// Commits seit 7 Tagen (`GitTimestamp`).
    case since7d
    /// Commits seit 30 Tagen (`GitTimestamp`).
    case since30d
    /// Issues geändert seit 7 Tagen (`DateTime`, z. B. `filterBy: {since:}`).
    case updatedSince7d

    public var graphQLType: String {
        switch self {
        case .since7d, .since30d: "GitTimestamp!"
        case .updatedSince7d: "DateTime!"
        }
    }

    public func value(now: Date) -> GraphQLVariable {
        let days = switch self {
        case .since7d, .updatedSince7d: 7.0
        case .since30d: 30.0
        }
        let date = now.addingTimeInterval(-days * 86_400)
        return .string(date.formatted(.iso8601))
    }

    public static func < (lhs: QueryVariable, rhs: QueryVariable) -> Bool { lhs.rawValue < rhs.rawValue }
}

/// Felder, die ein Modul in der Detail-Abfrage pro Repository braucht (Konzept 9.2, Punkt 1).
///
/// Jedes Feld der obersten Ebene muss mit dem Präfix des Moduls aliasiert sein,
/// z. B. `m_issues_open: issues(states: OPEN) { totalCount }`.
public struct GraphQLFragment: Sendable, Equatable {
    public let selection: String
    public let variables: Set<QueryVariable>

    public init(_ selection: String, variables: Set<QueryVariable> = []) {
        self.selection = selection
        self.variables = variables
    }
}

public struct ModuleMetadata: Sendable, Equatable {
    public let title: String
    public let systemImage: String
    /// Kleinere Werte stehen weiter vorn (Reiter, Abschnitte).
    public let defaultOrder: Int

    public init(title: String, systemImage: String, defaultOrder: Int) {
        self.title = title
        self.systemImage = systemImage
        self.defaultOrder = defaultOrder
    }
}

/// Informationen, die ein Modul beim Dekodieren braucht.
public struct ModuleContext: Sendable {
    public let viewerLogin: String
    public let now: Date

    public init(viewerLogin: String, now: Date) {
        self.viewerLogin = viewerLogin
        self.now = now
    }
}

/// Ein Repository-Knoten aus der Detail-Antwort. Module lesen daraus ihre eigenen Felder.
public struct RepositoryNode: Sendable {
    public let id: String
    public let json: JSONValue
    private let data: Data

    public init(json: JSONValue) throws {
        guard let id = json["id"]?.stringValue else {
            throw GitHubAPIError.decoding("Repository-Knoten ohne id")
        }
        self.id = id
        self.json = json
        data = try JSONEncoder().encode(json)
    }

    /// Dekodiert den Knoten (oder Teile davon) in einen eigenen Typ des Moduls.
    public func decode<T: Decodable>(_ type: T.Type = T.self) throws -> T {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(type, from: data)
    }
}

/// REST-Folgeanfrage eines Moduls (Konzept 9.2), z. B. `actions/runs` für ein Repo.
public struct SupplementaryRequest: Sendable, Hashable {
    /// Kennung innerhalb des Moduls, damit es die Antworten zuordnen kann.
    public let key: String
    public let path: String
    public let query: [URLQueryItem]

    public init(key: String, path: String, query: [URLQueryItem] = []) {
        self.key = key
        self.path = path
        self.query = query
    }
}

public struct SupplementaryResponse: Sendable {
    public let request: SupplementaryRequest
    public let result: Result<Data, GitHubAPIError>
    /// `true` bei `304 Not Modified` (kostenlos, Konzept 4.3).
    public let isFromCache: Bool

    public init(request: SupplementaryRequest, result: Result<Data, GitHubAPIError>, isFromCache: Bool) {
        self.request = request
        self.result = result
        self.isFromCache = isFromCache
    }

    /// Dekodiert eine REST-Antwort (snake_case → camelCase, ISO-8601-Daten).
    public func decode<T: Decodable>(_ type: T.Type = T.self) throws -> T {
        let data = try result.get()
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(type, from: data)
    }
}

/// Eine Funktion von RepoWatch (Konzept 9.2). Neue Funktionen sind neue Module;
/// der Sync-Kern muss dafür nicht geändert werden.
///
/// Die Darstellung (Repo-Zeile, Detail-Abschnitt, Reiter) kommt in Phase 4 als eigenes
/// Protokoll dazu, damit dieses Target ohne SwiftUI testbar bleibt.
public protocol InsightModule: Sendable {
    associatedtype Payload: ModulePayload

    static var id: ModuleID { get }
    var metadata: ModuleMetadata { get }

    /// Felder pro Repository in der gemeinsamen Detail-Abfrage.
    var fragment: GraphQLFragment { get }

    /// Liest die eigenen Felder aus dem Repository-Knoten.
    func decode(_ node: RepositoryNode, context: ModuleContext) throws -> Payload

    /// Zähler und Signale für Repo-Zeile, Menüleiste und Scheduler.
    func summarize(_ payload: Payload, context: ModuleContext) -> ModuleSummary

    /// Optionale REST-Folgeanfragen (z. B. `actions/runs`); werden gedrosselt und mit ETag ausgeführt.
    func supplementaryRequests(for repository: RepoMeta, payload: Payload) -> [SupplementaryRequest]

    /// Baut die Antworten der Folgeanfragen in den Payload ein. `previous` ist der Stand des
    /// letzten Durchlaufs, damit ein Modul bei fehlgeschlagenen Folgeanfragen alte Daten behalten kann.
    func merge(_ payload: Payload, with responses: [SupplementaryResponse], previous: Payload?) throws -> Payload

    /// Modulspezifische Änderungen zwischen zwei Ständen (z. B. neues Issue).
    func changes(from old: Payload?, to new: Payload, repository: RepoMeta) -> [Change]
}

extension InsightModule {
    public var id: ModuleID { Self.id }

    public func supplementaryRequests(for repository: RepoMeta, payload: Payload) -> [SupplementaryRequest] { [] }
    public func merge(_ payload: Payload, with responses: [SupplementaryResponse], previous: Payload?) throws -> Payload {
        payload
    }
    public func changes(from old: Payload?, to new: Payload, repository: RepoMeta) -> [Change] { [] }
}
