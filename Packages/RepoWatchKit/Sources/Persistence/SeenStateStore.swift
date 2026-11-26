import Foundation
import Synchronization

/// Wann der Nutzer zuletzt hingeschaut hat; Grundlage für „neu seit dem letzten Öffnen“ (Konzept 3.2).
public struct SeenState: Codable, Sendable, Equatable {
    /// Zeitpunkt, an dem das Panel zuletzt geöffnet wurde.
    public var panelOpenedAt: Date?
    /// Je Repo-ID: wann der Nutzer die Detailansicht zuletzt gesehen hat.
    public var repositorySeenAt: [String: Date]

    public init(panelOpenedAt: Date? = nil, repositorySeenAt: [String: Date] = [:]) {
        self.panelOpenedAt = panelOpenedAt
        self.repositorySeenAt = repositorySeenAt
    }

    /// Gilt etwas, das zum Zeitpunkt `date` passiert ist, als neu für dieses Repo?
    public func isNew(_ date: Date, repositoryID: String) -> Bool {
        let reference = [panelOpenedAt, repositorySeenAt[repositoryID]].compactMap { $0 }.max()
        guard let reference else { return false }
        return date > reference
    }
}

public protocol SeenStateStore: Sendable {
    func load() throws -> SeenState
    func save(_ state: SeenState) throws
    func clear() throws
}

public struct JSONFileSeenStateStore: SeenStateStore {
    public let fileURL: URL

    public init(fileURL: URL) {
        self.fileURL = fileURL
    }

    public func load() throws -> SeenState {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return SeenState() }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(SeenState.self, from: Data(contentsOf: fileURL))
    }

    public func save(_ state: SeenState) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try encoder.encode(state).write(to: fileURL, options: [.atomic])
    }

    public func clear() throws {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
        try FileManager.default.removeItem(at: fileURL)
    }
}

public final class InMemorySeenStateStore: SeenStateStore {
    private let state = Mutex(SeenState())
    public init() {}
    public func load() throws -> SeenState { state.withLock { $0 } }
    public func save(_ newState: SeenState) throws { state.withLock { $0 = newState } }
    public func clear() throws { state.withLock { $0 = SeenState() } }
}
