import Foundation

public enum GitHubAPIError: Error, Sendable, Equatable {
    /// Es ist kein Token hinterlegt.
    case missingToken
    /// GitHub hat das Token abgelehnt (HTTP 401).
    case unauthorized
    /// Kein Netzwerk.
    case offline
    /// Primäres oder sekundäres Rate-Limit erreicht.
    case rateLimited(resetAt: Date?)
    /// Serverfehler (5xx). 502 kommt auch bei zu schweren GraphQL-Abfragen (Konzept 4.3).
    case server(status: Int)
    /// Sonstiger HTTP-Fehler (4xx).
    case http(status: Int)
    case graphQL([GraphQLError])
    case decoding(String)
    case transport(String)
    /// HTTP 202: GitHub berechnet die Daten noch (z. B. `stats/*`); später erneut fragen.
    case pending
}

extension GitHubAPIError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .missingToken: String(localized: "Kein GitHub-Token vorhanden.")
        case .unauthorized: String(localized: "GitHub hat das Token abgelehnt.")
        case .offline: String(localized: "Keine Internetverbindung.")
        case .rateLimited(let resetAt):
            if let resetAt {
                String(localized: "GitHub-Kontingent erschöpft bis \(resetAt.formatted(date: .omitted, time: .shortened)).")
            } else {
                String(localized: "GitHub-Kontingent erschöpft.")
            }
        case .server(let status): String(localized: "GitHub ist gerade nicht erreichbar (HTTP \(status)).")
        case .http(let status): String(localized: "GitHub antwortete mit HTTP \(status).")
        case .graphQL(let errors): errors.map(\.message).joined(separator: "\n")
        case .decoding(let detail): String(localized: "Antwort nicht lesbar: \(detail)")
        case .transport(let detail): String(localized: "Netzwerkfehler: \(detail)")
        case .pending: String(localized: "GitHub berechnet die Daten noch.")
        }
    }
}
