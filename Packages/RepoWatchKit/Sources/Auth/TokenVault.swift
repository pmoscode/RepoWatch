import Foundation
import GitHubAPI

/// Hält das aktuelle Token im Speicher und liefert es an `HTTPTransport`.
///
/// Reihenfolge: Umgebungsvariable (nur Debug) vor gespeichertem Token. Der Schlüsselbund
/// wird nur einmal gelesen; danach kommt das Token aus dem Speicher.
public actor TokenVault: TokenProviding {
    private let store: any TokenStore
    private var environmentToken: StoredToken?
    private var cached: StoredToken?
    private var didLoad = false

    public init(store: any TokenStore, environmentToken: StoredToken? = nil) {
        self.store = store
        self.environmentToken = environmentToken
    }

    /// Aktuelles Token oder `nil`, wenn niemand angemeldet ist.
    public func current() throws -> StoredToken? {
        if let environmentToken { return environmentToken }
        if !didLoad {
            cached = try store.load()
            didLoad = true
        }
        return cached
    }

    public func token() async throws -> String {
        guard let token = try current() else { throw GitHubAPIError.missingToken }
        return token.value
    }

    public func save(_ token: StoredToken) throws {
        try store.save(token)
        cached = token
        didLoad = true
    }

    /// Abmelden: löscht das gespeicherte Token und vergisst ein Umgebungs-Token für diese Sitzung.
    public func clear() throws {
        environmentToken = nil
        cached = nil
        didLoad = true
        try store.delete()
    }
}
