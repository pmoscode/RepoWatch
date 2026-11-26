import Domain
import Foundation

/// Takte aus Konzept 4.2.
public struct RefreshPolicy: Sendable, Equatable {
    public var shortTickInterval: TimeInterval = 60
    public var activeInterval: TimeInterval = 5 * 60
    public var dormantInterval: TimeInterval = 30 * 60
    public var inventoryInterval: TimeInterval = 30 * 60
    /// Beim Öffnen des Panels werden aktive Repos aktualisiert, deren Daten älter sind.
    public var panelOpenStaleness: TimeInterval = 60
    /// Push oder Änderung innerhalb dieses Zeitraums → aktiv.
    public var activeWindow: TimeInterval = 7 * 86_400

    public init() {}

    public static let `default` = RefreshPolicy()
}

/// Warum aktualisiert wird.
public enum RefreshTrigger: Sendable, Equatable {
    /// App-Start oder neue Anmeldung: alles.
    case launch
    /// ⌘R oder „Aktualisieren“: alles.
    case manual
    /// Panel geöffnet: aktive Repos mit älteren Daten.
    case panelOpened
    /// Aufwachen aus dem Ruhezustand oder Netzwerk wieder da: alles Fällige, Bestand eher früher.
    case wake
    /// Regulärer Takt.
    case timer
}

/// Was ein Sync-Durchlauf tun soll.
public struct SyncPlan: Sendable, Equatable {
    public var inventory: Bool
    /// Details für diese Repos. Neu im Bestand entdeckte Repos kommen immer dazu.
    public var repositoryIDs: Set<String>
    /// Details für **alle** beobachteten Repos, auch die erst durch den Bestand bekannten.
    public var allRepositories: Bool

    public init(inventory: Bool, repositoryIDs: Set<String>, allRepositories: Bool = false) {
        self.inventory = inventory
        self.repositoryIDs = repositoryIDs
        self.allRepositories = allRepositories
    }

    public var isEmpty: Bool { !inventory && repositoryIDs.isEmpty && !allRepositories }
    public static let nothing = SyncPlan(inventory: false, repositoryIDs: [])
    /// Bestand und Details für alles (Start, manuell).
    public static let full = SyncPlan(inventory: true, repositoryIDs: [], allRepositories: true)
}

/// Entscheidet, welche Repos wann fällig sind. Reine Funktionen, daher leicht testbar.
public struct RefreshPlanner: Sendable {
    public var policy: RefreshPolicy
    public var favorites: Set<String>

    public init(policy: RefreshPolicy = .default, favorites: Set<String> = []) {
        self.policy = policy
        self.favorites = favorites
    }

    public func tier(of repository: RepoSnapshot, now: Date) -> RepoTier {
        if repository.wantsFrequentRefresh { return .shortTick }
        if favorites.contains(repository.meta.nameWithOwner) { return .active }
        let lastActivity = [repository.meta.pushedAt, repository.meta.updatedAt].compactMap { $0 }.max()
        if let lastActivity, now.timeIntervalSince(lastActivity) <= policy.activeWindow { return .active }
        return .dormant
    }

    public func interval(for tier: RepoTier) -> TimeInterval {
        switch tier {
        case .shortTick: policy.shortTickInterval
        case .active: policy.activeInterval
        case .dormant: policy.dormantInterval
        }
    }

    public func plan(for state: SyncState, trigger: RefreshTrigger, now: Date) -> SyncPlan {
        guard let inventoryAt = state.inventoryFetchedAt else { return .full }

        switch trigger {
        case .launch, .manual:
            return .full

        case .panelOpened:
            let stale = state.repositories.filter { repository in
                tier(of: repository, now: now) != .dormant
                    && isOlder(repository.detailsFetchedAt, than: policy.panelOpenStaleness, now: now)
            }
            var plan = dueWork(state: state, inventoryAt: inventoryAt, inventoryInterval: policy.inventoryInterval, now: now)
            plan.repositoryIDs.formUnion(stale.map(\.id))
            return plan

        case .wake:
            return dueWork(state: state, inventoryAt: inventoryAt, inventoryInterval: policy.activeInterval, now: now)

        case .timer:
            return dueWork(state: state, inventoryAt: inventoryAt, inventoryInterval: policy.inventoryInterval, now: now)
        }
    }

    /// Wann frühestens wieder etwas fällig ist; der Scheduler schläft bis dahin.
    public func nextDueDate(for state: SyncState, now: Date) -> Date {
        guard let inventoryAt = state.inventoryFetchedAt else { return now }
        var dates = [inventoryAt.addingTimeInterval(policy.inventoryInterval)]
        for repository in state.repositories {
            guard let fetched = repository.detailsFetchedAt else { return now }
            dates.append(fetched.addingTimeInterval(interval(for: tier(of: repository, now: now))))
        }
        return dates.min() ?? now
    }

    private func dueWork(state: SyncState, inventoryAt: Date, inventoryInterval: TimeInterval, now: Date) -> SyncPlan {
        let due = state.repositories.filter { repository in
            isOlder(repository.detailsFetchedAt, than: interval(for: tier(of: repository, now: now)), now: now)
        }
        return SyncPlan(
            inventory: now.timeIntervalSince(inventoryAt) >= inventoryInterval,
            repositoryIDs: Set(due.map(\.id))
        )
    }

    private func isOlder(_ date: Date?, than interval: TimeInterval, now: Date) -> Bool {
        guard let date else { return true }
        return now.timeIntervalSince(date) >= interval
    }
}
