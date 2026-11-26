import Foundation

/// Aktualisierungs-Stufe eines Repos (Konzept 4.2).
public enum RepoTier: String, Codable, Sendable, Comparable {
    case shortTick
    case active
    case dormant

    private var order: Int {
        switch self {
        case .shortTick: 0
        case .active: 1
        case .dormant: 2
        }
    }

    public static func < (lhs: RepoTier, rhs: RepoTier) -> Bool { lhs.order < rhs.order }
}

/// Alles, was RepoWatch über ein Repository weiß: Stammdaten plus die Daten aller Module.
public struct RepoSnapshot: Sendable, Equatable, Identifiable {
    public var id: String { meta.id }
    public var meta: RepoMeta
    public var payloads: [ModuleID: AnyPayload]
    public var summaries: [ModuleID: ModuleSummary]
    /// Zeitpunkt der letzten erfolgreichen Detail-Abfrage; `nil` = noch nie.
    public var detailsFetchedAt: Date?
    /// Fehler der letzten Detail-Abfrage, falls sie für dieses Repo scheiterte.
    public var lastDetailError: String?

    public init(
        meta: RepoMeta,
        payloads: [ModuleID: AnyPayload] = [:],
        summaries: [ModuleID: ModuleSummary] = [:],
        detailsFetchedAt: Date? = nil,
        lastDetailError: String? = nil
    ) {
        self.meta = meta
        self.payloads = payloads
        self.summaries = summaries
        self.detailsFetchedAt = detailsFetchedAt
        self.lastDetailError = lastDetailError
    }

    public func payload<P: ModulePayload>(_ type: P.Type, for module: ModuleID) -> P? {
        payloads[module]?.as(type)
    }

    public var needsAttention: Bool { summaries.values.contains(where: \.needsAttention) }
    public var wantsFrequentRefresh: Bool { summaries.values.contains(where: \.wantsFrequentRefresh) }
}

extension RepoSnapshot: Codable {
    private enum CodingKeys: String, CodingKey {
        case meta, payloads, summaries, detailsFetchedAt, lastDetailError
    }

    private struct ModuleKey: CodingKey {
        let stringValue: String
        var intValue: Int? { nil }
        init(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { nil }
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        meta = try container.decode(RepoMeta.self, forKey: .meta)
        detailsFetchedAt = try container.decodeIfPresent(Date.self, forKey: .detailsFetchedAt)
        lastDetailError = try container.decodeIfPresent(String.self, forKey: .lastDetailError)

        let rawSummaries = try container.decodeIfPresent([String: ModuleSummary].self, forKey: .summaries) ?? [:]
        let types = decoder.userInfo[.modulePayloadTypes] as? [ModuleID: any ModulePayload.Type] ?? [:]

        // Payloads unbekannter oder nicht mehr lesbarer Module werden verworfen (Modul entfernt
        // oder Format geändert); das Repo wird dann einfach neu abgefragt.
        var payloads: [ModuleID: AnyPayload] = [:]
        if container.contains(.payloads) {
            let nested = try container.nestedContainer(keyedBy: ModuleKey.self, forKey: .payloads)
            for key in nested.allKeys {
                let id = ModuleID(key.stringValue)
                guard let type = types[id], let value = try? Self.decode(type, from: nested, key: key) else { continue }
                payloads[id] = AnyPayload(value)
            }
        }
        self.payloads = payloads
        summaries = Dictionary(uniqueKeysWithValues: rawSummaries.compactMap { key, value in
            let id = ModuleID(key)
            return payloads[id] == nil ? nil : (id, value)
        })
        if payloads.count != rawSummaries.count {
            detailsFetchedAt = nil
        }
    }

    private static func decode<P: ModulePayload>(
        _ type: P.Type,
        from container: KeyedDecodingContainer<ModuleKey>,
        key: ModuleKey
    ) throws -> P {
        try container.decode(type, forKey: key)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(meta, forKey: .meta)
        try container.encodeIfPresent(detailsFetchedAt, forKey: .detailsFetchedAt)
        try container.encodeIfPresent(lastDetailError, forKey: .lastDetailError)
        try container.encode(
            Dictionary(uniqueKeysWithValues: summaries.map { ($0.key.rawValue, $0.value) }),
            forKey: .summaries
        )
        var nested = container.nestedContainer(keyedBy: ModuleKey.self, forKey: .payloads)
        for (id, payload) in payloads {
            try nested.encode(payload.value, forKey: ModuleKey(stringValue: id.rawValue))
        }
    }
}

/// Gesamter Stand, den die `SyncEngine` hält und speichert.
public struct SyncState: Codable, Sendable, Equatable {
    public var viewerLogin: String
    public var inventoryFetchedAt: Date?
    /// Letzter erfolgreicher Sync (Bestand oder Details).
    public var lastSyncAt: Date?
    public var rateLimit: RateLimitInfo?
    /// Beobachtete, gefilterte Repos, zuletzt gepusht zuerst.
    public var repositories: [RepoSnapshot]

    public init(
        viewerLogin: String,
        inventoryFetchedAt: Date? = nil,
        lastSyncAt: Date? = nil,
        rateLimit: RateLimitInfo? = nil,
        repositories: [RepoSnapshot] = []
    ) {
        self.viewerLogin = viewerLogin
        self.inventoryFetchedAt = inventoryFetchedAt
        self.lastSyncAt = lastSyncAt
        self.rateLimit = rateLimit
        self.repositories = repositories
    }

    public static let empty = SyncState(viewerLogin: "")
}
