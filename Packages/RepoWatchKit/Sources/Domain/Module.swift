import Foundation

/// Eindeutige Kennung eines Moduls (Konzept 9.2).
public struct ModuleID: RawRepresentable, Hashable, Codable, Sendable, CustomStringConvertible {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public init(_ rawValue: String) { self.rawValue = rawValue }

    /// Präfix für die Feldnamen des Moduls in der gemeinsamen Detail-Abfrage, z. B. `m_issues_`.
    public var fieldPrefix: String { "m_\(rawValue)_" }
    public var description: String { rawValue }
}

/// Daten, die ein Modul pro Repository ablegt. Muss speicherbar sein (Cache, Konzept 9.5).
public protocol ModulePayload: Codable, Sendable, Equatable {}

extension ModulePayload {
    /// Vergleicht mit einem Payload unbekannten Typs.
    func isEqual(to other: any ModulePayload) -> Bool {
        guard let other = other as? Self else { return false }
        return self == other
    }
}

/// Typgelöschter Payload für `RepoSnapshot.payloads`.
public struct AnyPayload: Sendable, Equatable {
    public let value: any ModulePayload

    public init(_ value: any ModulePayload) {
        self.value = value
    }

    public func `as`<P: ModulePayload>(_ type: P.Type) -> P? {
        value as? P
    }

    public static func == (lhs: AnyPayload, rhs: AnyPayload) -> Bool {
        lhs.value.isEqual(to: rhs.value)
    }
}

/// Kurzfassung eines Moduls für Repo-Zeile und Menüleiste (Konzept 9.2, Punkt 3).
public struct ModuleSummary: Codable, Sendable, Equatable {
    /// Zähler, z. B. `["open": 4]` oder `["human": 1, "renovate": 3]`.
    public var counts: [String: Int]
    /// Etwas braucht Aufmerksamkeit (z. B. fehlgeschlagener Workflow, E7).
    public var needsAttention: Bool
    /// Das Repo soll im Kurztakt aktualisiert werden (z. B. laufender Workflow, Konzept 4.2).
    public var wantsFrequentRefresh: Bool

    public init(counts: [String: Int] = [:], needsAttention: Bool = false, wantsFrequentRefresh: Bool = false) {
        self.counts = counts
        self.needsAttention = needsAttention
        self.wantsFrequentRefresh = wantsFrequentRefresh
    }
}

extension CodingUserInfoKey {
    /// `[ModuleID: any ModulePayload.Type]` – nötig, um gespeicherte Payloads zu dekodieren.
    public static let modulePayloadTypes = CodingUserInfoKey(rawValue: "de.pmoscode.repowatch.modulePayloadTypes")!
}
