/// Eindeutige Kennung eines Moduls (Konzept 9.2).
/// Das `InsightModule`-Protokoll und der QueryBuilder folgen in Phase 2.
public struct ModuleID: RawRepresentable, Hashable, Codable, Sendable {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }

    /// Präfix für die Feldnamen des Moduls in der gemeinsamen Detail-Abfrage, z. B. `m_issues_`.
    public var fieldPrefix: String { "m_\(rawValue)_" }
}
