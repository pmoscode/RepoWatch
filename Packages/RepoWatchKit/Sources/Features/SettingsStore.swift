import Foundation
import ModuleUIKit
import Synchronization

/// Speichert die Einstellungen (Konzept 3.3).
public protocol SettingsStore: Sendable {
    func load() -> AppSettings
    func save(_ settings: AppSettings)
}

/// JSON in den `UserDefaults` der App (in der Sandbox: im Container).
public struct UserDefaultsSettingsStore: SettingsStore {
    private let key: String

    public init(key: String = "de.pmoscode.repowatch.settings") {
        self.key = key
    }

    public func load() -> AppSettings {
        guard let data = UserDefaults.standard.data(forKey: key),
              let settings = try? JSONDecoder().decode(AppSettings.self, from: data) else { return AppSettings() }
        return settings
    }

    public func save(_ settings: AppSettings) {
        guard let data = try? JSONEncoder().encode(settings) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }
}

public final class InMemorySettingsStore: SettingsStore {
    private let settings: Mutex<AppSettings>
    public init(_ settings: AppSettings = AppSettings()) { self.settings = Mutex(settings) }
    public func load() -> AppSettings { settings.withLock { $0 } }
    public func save(_ newValue: AppSettings) { settings.withLock { $0 = newValue } }
}
