import Foundation
import GitHubAPI

public enum AuthError: Error, Sendable {
    case noToken
}

/// Liest das Token aus der Umgebungsvariable `GITHUB_TOKEN`.
///
/// Nur für die Entwicklung (Phase 0). Device Flow, PAT-Eingabe und
/// Schlüsselbund folgen in Phase 1.
public struct EnvironmentTokenProvider: TokenProviding {
    public let variableName: String

    public init(variableName: String = "GITHUB_TOKEN") {
        self.variableName = variableName
    }

    public var isAvailable: Bool {
        guard let value = ProcessInfo.processInfo.environment[variableName] else { return false }
        return !value.isEmpty
    }

    public func token() async throws -> String {
        guard let value = ProcessInfo.processInfo.environment[variableName], !value.isEmpty else {
            throw AuthError.noToken
        }
        return value
    }
}
