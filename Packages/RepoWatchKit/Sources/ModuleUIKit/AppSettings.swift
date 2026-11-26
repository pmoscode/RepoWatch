import Domain
import Foundation

/// Alle Einstellungen der App (Konzept 3.3). Module lesen daraus, was sie betrifft.
///
/// Fehlende Felder (ältere gespeicherte Version) bekommen ihren Standardwert, damit neue
/// Einstellungen keine alten verwerfen.
public struct AppSettings: Codable, Sendable, Equatable {
    public enum MenuBarMode: String, Codable, Sendable, CaseIterable, Identifiable {
        case none
        case newItemsDot
        case personPullRequests
        case openItems

        public var id: String { rawValue }
    }

    public enum OverviewSort: String, Codable, Sendable, CaseIterable, Identifiable {
        case activity, name, lastPush, openItems
        public var id: String { rawValue }
    }

    // Repositories
    public var includeArchived = false
    public var includeForks = true
    public var excludedOwners: [String] = []
    public var excludedPatterns: [String] = []
    public var favorites: [String] = []

    // Pull Requests
    public var authorRules = AuthorRules.default

    // Issues
    /// Issues von Bots (z. B. Renovates „Dependency Dashboard“) ausblenden und nicht mitzählen.
    public var issuesHideBotIssues = true

    // Actions
    /// Actions-Reiter: auch Fehlschläge auf anderen Branches als dem Standard-Branch zeigen.
    public var actionsShowAllBranches = true
    /// Runs aus Renovate-/Dependabot-/Bot-PRs im Actions-Reiter ausblenden.
    public var actionsHideBotRuns = false
    /// Auslöser, die im Actions-Reiter ausgeblendet werden, z. B. `schedule`.
    public var actionsHiddenEvents: [String] = []
    /// Roter Punkt in der Menüleiste bei Alarm (E7).
    public var alarmDotEnabled = true

    // Aktualisierung (Minuten)
    public var activeIntervalMinutes = 5
    public var dormantIntervalMinutes = 30

    // Module
    public var disabledModules: [String] = []

    // Allgemein
    public var menuBarMode = MenuBarMode.newItemsDot
    public var overviewSort = OverviewSort.activity

    public init() {}

    public func isFavorite(_ nameWithOwner: String) -> Bool {
        favorites.contains(nameWithOwner)
    }

    public func isEnabled(_ module: ModuleID) -> Bool {
        !disabledModules.contains(module.rawValue)
    }

    // MARK: Kodierung mit Standardwerten

    private enum CodingKeys: String, CodingKey {
        case includeArchived, includeForks, excludedOwners, excludedPatterns, favorites
        case authorRules
        case issuesHideBotIssues
        case actionsShowAllBranches, actionsHideBotRuns, actionsHiddenEvents, alarmDotEnabled
        case activeIntervalMinutes, dormantIntervalMinutes
        case disabledModules
        case menuBarMode, overviewSort
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = AppSettings()
        includeArchived = (try? c.decodeIfPresent(Bool.self, forKey: .includeArchived)) ?? d.includeArchived
        includeForks = (try? c.decodeIfPresent(Bool.self, forKey: .includeForks)) ?? d.includeForks
        excludedOwners = (try? c.decodeIfPresent([String].self, forKey: .excludedOwners)) ?? d.excludedOwners
        excludedPatterns = (try? c.decodeIfPresent([String].self, forKey: .excludedPatterns)) ?? d.excludedPatterns
        favorites = (try? c.decodeIfPresent([String].self, forKey: .favorites)) ?? d.favorites
        authorRules = (try? c.decodeIfPresent(AuthorRules.self, forKey: .authorRules)) ?? d.authorRules
        issuesHideBotIssues = (try? c.decodeIfPresent(Bool.self, forKey: .issuesHideBotIssues)) ?? d.issuesHideBotIssues
        actionsShowAllBranches = (try? c.decodeIfPresent(Bool.self, forKey: .actionsShowAllBranches)) ?? d.actionsShowAllBranches
        actionsHideBotRuns = (try? c.decodeIfPresent(Bool.self, forKey: .actionsHideBotRuns)) ?? d.actionsHideBotRuns
        actionsHiddenEvents = (try? c.decodeIfPresent([String].self, forKey: .actionsHiddenEvents)) ?? d.actionsHiddenEvents
        alarmDotEnabled = (try? c.decodeIfPresent(Bool.self, forKey: .alarmDotEnabled)) ?? d.alarmDotEnabled
        activeIntervalMinutes = (try? c.decodeIfPresent(Int.self, forKey: .activeIntervalMinutes)) ?? d.activeIntervalMinutes
        dormantIntervalMinutes = (try? c.decodeIfPresent(Int.self, forKey: .dormantIntervalMinutes)) ?? d.dormantIntervalMinutes
        disabledModules = (try? c.decodeIfPresent([String].self, forKey: .disabledModules)) ?? d.disabledModules
        menuBarMode = (try? c.decodeIfPresent(MenuBarMode.self, forKey: .menuBarMode)) ?? d.menuBarMode
        overviewSort = (try? c.decodeIfPresent(OverviewSort.self, forKey: .overviewSort)) ?? d.overviewSort
    }
}
