import Domain
import Foundation
import Synchronization

/// Speichert den letzten `SyncState`, damit das Panel nach dem Start sofort Daten zeigt
/// (Leitprinzip 2, Konzept 9.5).
public protocol SnapshotStore: Sendable {
    func load(payloadTypes: [ModuleID: any ModulePayload.Type]) throws -> SyncState?
    func save(_ state: SyncState) throws
    func clear() throws
}

/// Dateiformat mit Versionsfeld für spätere Migrationen.
/// Zeitpunkte werden verlustfrei als interner `Date`-Wert gespeichert: ISO-Text verlöre
/// Sekundenbruchteile, die Umrechnung auf 1970 erzeugt Rundungsfehler.
struct PersistedSnapshot: Codable {
    // 2: Zeitpunkte als `Date`-Rohwert statt ISO-Text.
    static let currentVersion = 2
    let version: Int
    let savedAt: Date
    let state: SyncState
}

public enum SnapshotStoreError: Error, Sendable, Equatable, LocalizedError {
    case unsupportedVersion(Int)

    public var errorDescription: String? {
        switch self {
        case .unsupportedVersion(let version):
            String(localized: "Cache-Format \(version) wird nicht unterstützt (erwartet \(PersistedSnapshot.currentVersion)).")
        }
    }
}

/// JSON-Datei im Application-Support-Ordner (in der Sandbox: im Container der App).
public struct JSONFileSnapshotStore: SnapshotStore {
    public let fileURL: URL

    public init(fileURL: URL) {
        self.fileURL = fileURL
    }

    /// `~/Library/Containers/de.pmoscode.repowatch/Data/Library/Application Support/RepoWatch/snapshot.json`
    public static func defaultLocation(fileName: String = "snapshot.json") throws -> URL {
        let base = try FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true
        )
        return base.appending(path: "RepoWatch", directoryHint: .isDirectory).appending(path: fileName)
    }

    public func load(payloadTypes: [ModuleID: any ModulePayload.Type]) throws -> SyncState? {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return nil }
        let data = try Data(contentsOf: fileURL)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .deferredToDate
        decoder.userInfo[.modulePayloadTypes] = payloadTypes

        // Erst nur die Version lesen: Ein veraltetes Format wird verworfen statt falsch gelesen.
        struct VersionProbe: Decodable { let version: Int }
        let version = try decoder.decode(VersionProbe.self, from: data).version
        guard version == PersistedSnapshot.currentVersion else {
            throw SnapshotStoreError.unsupportedVersion(version)
        }
        return try decoder.decode(PersistedSnapshot.self, from: data).state
    }

    public func save(_ state: SyncState) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .deferredToDate
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(
            PersistedSnapshot(version: PersistedSnapshot.currentVersion, savedAt: Date(), state: state)
        )
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try data.write(to: fileURL, options: [.atomic, .completeFileProtection])
    }

    public func clear() throws {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
        try FileManager.default.removeItem(at: fileURL)
    }
}

/// Für Tests und Previews. Kodiert trotzdem wirklich, damit Tests den Rundweg prüfen.
public final class InMemorySnapshotStore: SnapshotStore {
    private let data = Mutex<Data?>(nil)

    public init() {}

    public var hasData: Bool { data.withLock { $0 != nil } }

    public func load(payloadTypes: [ModuleID: any ModulePayload.Type]) throws -> SyncState? {
        guard let stored = data.withLock({ $0 }) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .deferredToDate
        decoder.userInfo[.modulePayloadTypes] = payloadTypes
        return try decoder.decode(PersistedSnapshot.self, from: stored).state
    }

    public func save(_ state: SyncState) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .deferredToDate
        let encoded = try encoder.encode(
            PersistedSnapshot(version: PersistedSnapshot.currentVersion, savedAt: Date(), state: state)
        )
        data.withLock { $0 = encoded }
    }

    public func clear() throws {
        data.withLock { $0 = nil }
    }
}
