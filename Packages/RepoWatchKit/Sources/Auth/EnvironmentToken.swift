import Foundation

/// Liest `GITHUB_TOKEN` aus der Umgebung. Wird nur in Debug-Builds genutzt
/// (Entwicklung, Screenshots); die App speichert dieses Token nie.
public enum EnvironmentToken {
    public static func read(variableName: String = "GITHUB_TOKEN") -> StoredToken? {
        guard let value = ProcessInfo.processInfo.environment[variableName], !value.isEmpty else {
            return nil
        }
        return StoredToken(value: value, kind: .environment, login: nil)
    }
}
