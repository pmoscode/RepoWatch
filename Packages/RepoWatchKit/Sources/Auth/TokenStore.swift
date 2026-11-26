import Foundation
import Security
import Synchronization

/// Gespeichertes Zugriffstoken samt Herkunft.
public struct StoredToken: Codable, Sendable, Equatable {
    public enum Kind: String, Codable, Sendable {
        /// OAuth-App über Device Flow (Standard, E2).
        case oauth
        /// Fine-grained oder klassisches Personal Access Token.
        case personalAccessToken
        /// `GITHUB_TOKEN` aus der Umgebung, nur Debug-Builds; wird nie gespeichert.
        case environment
    }

    public let value: String
    public let kind: Kind
    /// Login zum Zeitpunkt der Anmeldung; nur zur Anzeige.
    public let login: String?

    public init(value: String, kind: Kind, login: String?) {
        self.value = value
        self.kind = kind
        self.login = login
    }
}

public protocol TokenStore: Sendable {
    func load() throws -> StoredToken?
    func save(_ token: StoredToken) throws
    func delete() throws
}

// MARK: - Schlüsselbund

public enum KeychainError: Error, Sendable, Equatable, LocalizedError {
    case status(OSStatus)
    case corruptItem

    public var errorDescription: String? {
        switch self {
        case .status(let status):
            let message = SecCopyErrorMessageString(status, nil) as String? ?? "OSStatus \(status)"
            return String(localized: "Schlüsselbund: \(message)")
        case .corruptItem:
            return String(localized: "Schlüsselbund-Eintrag ist beschädigt.")
        }
    }
}

/// Speichert das Token als „Generic Password“ im Schlüsselbund dieses Macs (Konzept 5 und 11).
/// Es wird nicht über iCloud synchronisiert.
public struct KeychainTokenStore: TokenStore {
    public let service: String
    public let account: String

    public init(service: String = "de.pmoscode.repowatch", account: String = "github.com") {
        self.service = service
        self.account = account
    }

    private var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    public func load() throws -> StoredToken? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            guard let data = result as? Data else { throw KeychainError.corruptItem }
            do {
                return try JSONDecoder().decode(StoredToken.self, from: data)
            } catch {
                throw KeychainError.corruptItem
            }
        case errSecItemNotFound:
            return nil
        default:
            throw KeychainError.status(status)
        }
    }

    public func save(_ token: StoredToken) throws {
        let data = try JSONEncoder().encode(token)
        let update: [String: Any] = [kSecValueData as String: data]
        let status = SecItemUpdate(baseQuery as CFDictionary, update as CFDictionary)
        switch status {
        case errSecSuccess:
            return
        case errSecItemNotFound:
            var item = baseQuery
            item[kSecValueData as String] = data
            item[kSecAttrLabel as String] = "RepoWatch – GitHub-Token"
            item[kSecAttrSynchronizable as String] = false
            let addStatus = SecItemAdd(item as CFDictionary, nil)
            guard addStatus == errSecSuccess else { throw KeychainError.status(addStatus) }
        default:
            throw KeychainError.status(status)
        }
    }

    public func delete() throws {
        let status = SecItemDelete(baseQuery as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.status(status)
        }
    }
}

// MARK: - Arbeitsspeicher (Tests, Previews)

public final class InMemoryTokenStore: TokenStore {
    private let storage: Mutex<StoredToken?>

    public init(_ token: StoredToken? = nil) {
        storage = Mutex(token)
    }

    public func load() throws -> StoredToken? { storage.withLock { $0 } }
    public func save(_ token: StoredToken) throws { storage.withLock { $0 = token } }
    public func delete() throws { storage.withLock { $0 = nil } }
}
