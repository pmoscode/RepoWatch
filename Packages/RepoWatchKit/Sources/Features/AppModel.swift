import AppKit
import Auth
import Domain
import Foundation
import GitHubAPI
import ModuleKit
import ModuleUIKit
import Observation
import Persistence
import Sync
import os

/// Einstellungen, die die App beim Start mitgibt.
public struct AppConfiguration: Sendable {
    /// Client-ID der OAuth-App für den Device Flow; `nil`, solange keine hinterlegt ist.
    public var oauthClientID: String?
    public var tokenStore: any TokenStore
    /// Nur Debug-Builds: `GITHUB_TOKEN` hat Vorrang vor dem Schlüsselbund.
    public var environmentToken: StoredToken?
    public var snapshotStore: (any SnapshotStore)?
    public var seenStateStore: any SeenStateStore
    public var settingsStore: any SettingsStore
    /// Module für Daten und Darstellung (Konzept 9.2).
    public var modules: StandardModules
    public var batchSize: Int

    public init(
        oauthClientID: String?,
        tokenStore: any TokenStore,
        environmentToken: StoredToken? = nil,
        snapshotStore: (any SnapshotStore)? = nil,
        seenStateStore: any SeenStateStore = InMemorySeenStateStore(),
        settingsStore: any SettingsStore = InMemorySettingsStore(),
        modules: StandardModules = StandardModules(authorRules: SharedValue(.default)),
        batchSize: Int = 10
    ) {
        self.oauthClientID = oauthClientID
        self.tokenStore = tokenStore
        self.environmentToken = environmentToken
        self.snapshotStore = snapshotStore
        self.seenStateStore = seenStateStore
        self.settingsStore = settingsStore
        self.modules = modules
        self.batchSize = batchSize
    }

    /// Konfiguration der laufenden App: Schlüsselbund, Cache im Sandbox-Container, Client-ID aus
    /// der Info.plist und in Debug-Builds optional `GITHUB_TOKEN`. So muss die App-Schicht
    /// weder `Auth` noch `Persistence` kennen.
    public static func live(bundle: Bundle = .main, allowEnvironmentToken: Bool) -> AppConfiguration {
        let clientID = (bundle.object(forInfoDictionaryKey: "GitHubOAuthClientID") as? String)?
            .trimmingCharacters(in: .whitespaces)
        let isConfigured = clientID.map { !$0.isEmpty && !$0.hasPrefix("$(") } ?? false
        let snapshotURL = try? JSONFileSnapshotStore.defaultLocation()
        let seenURL = try? JSONFileSnapshotStore.defaultLocation(fileName: "seen.json")
        return AppConfiguration(
            oauthClientID: isConfigured ? clientID : nil,
            tokenStore: KeychainTokenStore(),
            environmentToken: allowEnvironmentToken ? EnvironmentToken.read() : nil,
            snapshotStore: snapshotURL.map(JSONFileSnapshotStore.init(fileURL:)),
            seenStateStore: seenURL.map { JSONFileSeenStateStore(fileURL: $0) as any SeenStateStore }
                ?? InMemorySeenStateStore(),
            settingsStore: UserDefaultsSettingsStore()
        )
    }
}

/// Was das Menüleisten-Symbol zeigt (Konzept 3.1).
public struct MenuBarIndicator: Equatable {
    /// Zahl neben dem Symbol (Modus „offene PRs von Menschen“ bzw. „Summe“).
    public var count: Int?
    /// Punkt in Akzentfarbe: Neues seit dem letzten Öffnen.
    public var showsNewDot: Bool
    /// Roter Punkt: Alarm nach E7.
    public var showsAlarm: Bool
}

/// Zentraler UI-Zustand (Konzept 9.3): Anmeldung, zuletzt bekannter Stand, Sync-Status.
@MainActor
@Observable
public final class AppModel {
    public enum AuthState: Equatable {
        case checking
        case signedOut(message: String?)
        case awaitingDeviceConfirmation(DeviceAuthorization)
        case validating
        case signedIn(login: String, kind: StoredToken.Kind)
    }

    public private(set) var auth: AuthState = .checking
    /// Zuletzt bekannter Stand; kommt beim Start sofort aus dem Cache (Leitprinzip 2).
    public private(set) var syncState: SyncState? {
        didSet {
            ui.repositories = syncState?.repositories ?? []
            ui.viewerLogin = syncState?.viewerLogin ?? ""
        }
    }
    public private(set) var isSyncing = false
    /// Fehler des letzten Durchlaufs; die alten Daten bleiben sichtbar.
    public private(set) var lastError: String?
    public private(set) var nextRetryAt: Date?
    public private(set) var lastChanges: ChangeSet?
    public private(set) var seenState = SeenState()
    public private(set) var settings: AppSettings
    public var isDeviceFlowAvailable: Bool { deviceFlow != nil }
    /// Kontext für die Oberfläche der Module.
    public let ui: ModuleUIContext
    /// Start bei Anmeldung.
    public let loginItem = LoginItemController()
    /// Alle Modul-Oberflächen in fester Reihenfolge; `enabledModuleUIs` berücksichtigt die Einstellungen.
    public let moduleUIs: [any ModuleUI]
    /// Nur Debug-Builds: Reiter bzw. Repo, das das Panel beim Öffnen zeigt (`--tab`, `--repo`).
    public var debugInitialTab: String?
    public var debugInitialRepository: String?

    private let vault: TokenVault
    private let engine: SyncEngine
    private let scheduler: RefreshScheduler
    private let deviceFlow: DeviceFlowAuthenticator?
    private let oauthClientID: String?
    private let seenStore: any SeenStateStore
    private let settingsStore: any SettingsStore
    private let authorRules: SharedValue<AuthorRules>
    private let ignoredWorkflowEvents: SharedValue<Set<String>>
    private var signInTask: Task<Void, Never>?
    private var eventsTask: Task<Void, Never>?
    private var systemEvents: SystemEventsMonitor?
    private let logger = Logger(subsystem: "de.pmoscode.repowatch", category: "AppModel")

    public init(configuration: AppConfiguration) {
        settingsStore = configuration.settingsStore
        let settings = configuration.settingsStore.load()
        self.settings = settings
        authorRules = configuration.modules.authorRules
        authorRules.value = settings.authorRules
        ignoredWorkflowEvents = configuration.modules.ignoredWorkflowEvents
        ignoredWorkflowEvents.value = Set(settings.actionsHiddenEvents)

        var registry: ModuleRegistry
        do {
            registry = try configuration.modules.registry()
        } catch {
            // Kann nur bei einem fehlerhaften Fragment passieren; Tests verhindern das.
            assertionFailure("Module nicht registrierbar: \(error)")
            registry = ModuleRegistry()
        }
        for module in registry.modules {
            registry.setEnabled(settings.isEnabled(module.id), for: module.id)
        }

        vault = TokenVault(store: configuration.tokenStore, environmentToken: configuration.environmentToken)
        let transport = HTTPTransport(tokenProvider: vault)
        let graphQL = GraphQLClient(transport: transport)
        let rest = RESTClient(transport: transport)
        engine = SyncEngine(
            client: graphQL,
            rest: rest,
            registry: registry,
            configuration: SyncConfiguration(batchSize: configuration.batchSize, filter: Self.filter(from: settings)),
            store: configuration.snapshotStore
        )
        scheduler = RefreshScheduler(
            engine: engine,
            planner: RefreshPlanner(policy: Self.policy(from: settings), favorites: Set(settings.favorites))
        )
        deviceFlow = configuration.oauthClientID.map { DeviceFlowAuthenticator(clientID: $0) }
        oauthClientID = configuration.oauthClientID
        seenStore = configuration.seenStateStore
        seenState = (try? seenStore.load()) ?? SeenState()
        moduleUIs = configuration.modules.userInterfaces()
        ui = ModuleUIContext(services: ModuleServices(graphQL: graphQL, rest: rest))
        ui.settings = settings
        ui.seen = seenState

        ui.showRepositoryAction = { [weak self] id in self?.requestedRepositoryID = id }
        ui.markSeenAction = { [weak self] id in self?.markSeen(id) }
        ui.toggleFavoriteAction = { [weak self] name in self?.toggleFavorite(name) }
        ui.updateSettingsAction = { [weak self] change in self?.updateSettings(change) }

        eventsTask = Task { [weak self, events = scheduler.events] in
            for await event in events {
                self?.handle(event)
            }
        }
        systemEvents = SystemEventsMonitor { [weak self] in
            self?.systemDidWake()
        }
    }

    /// Repo, das die Oberfläche anzeigen soll (z. B. aus einem Modul-Reiter heraus).
    public var requestedRepositoryID: String?

    public var isSignedIn: Bool {
        if case .signedIn = auth { true } else { false }
    }

    public var repositories: [RepoSnapshot] { syncState?.repositories ?? [] }
    public var visibleRepositories: [RepoMeta] { repositories.map(\.meta) }

    // MARK: Start

    /// Liest Token und Cache. Mit Token: Cache sofort anzeigen, dann im Hintergrund aktualisieren.
    public func start() {
        Task {
            do {
                guard let token = try await vault.current() else {
                    auth = .signedOut(message: nil)
                    return
                }
                if let restored = await engine.restore() {
                    if let login = token.login, !restored.viewerLogin.isEmpty, login != restored.viewerLogin {
                        // Cache gehört zu einem anderen Konto.
                        await engine.reset()
                    } else {
                        syncState = restored
                    }
                }
                auth = .signedIn(login: token.login ?? syncState?.viewerLogin ?? "", kind: token.kind)
                await scheduler.start(with: .launch)
            } catch {
                logger.error("Token nicht lesbar: \(error.localizedDescription, privacy: .public)")
                auth = .signedOut(message: error.localizedDescription)
            }
        }
    }

    // MARK: Anmelden

    public func signInWithDevice() {
        guard let deviceFlow else { return }
        signInTask?.cancel()
        signInTask = Task {
            do {
                let authorization = try await deviceFlow.start()
                auth = .awaitingDeviceConfirmation(authorization)
                let token = try await deviceFlow.waitForToken(authorization)
                try await completeSignIn(token: token, kind: .oauth)
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled else { return }
                logger.error("Device Flow fehlgeschlagen: \(error.localizedDescription, privacy: .public)")
                auth = .signedOut(message: error.localizedDescription)
            }
        }
    }

    public func signIn(personalAccessToken: String) {
        let token = personalAccessToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else { return }
        signInTask?.cancel()
        signInTask = Task {
            do {
                try await completeSignIn(token: token, kind: .personalAccessToken)
            } catch {
                guard !Task.isCancelled else { return }
                let message = (error as? GitHubAPIError) == .unauthorized
                    ? String(localized: "GitHub hat das Token abgelehnt. Ist es richtig kopiert und noch gültig?")
                    : error.localizedDescription
                auth = .signedOut(message: message)
            }
        }
    }

    public func cancelSignIn() {
        signInTask?.cancel()
        signInTask = nil
        auth = .signedOut(message: nil)
    }

    /// Prüft das Token mit `viewer { login }`, speichert es und startet den Sync.
    private func completeSignIn(token: String, kind: StoredToken.Kind) async throws {
        auth = .validating
        let probe = GraphQLClient(transport: HTTPTransport(tokenProvider: StaticTokenProvider(token), retryPolicy: .none))
        let login = try await probe.viewerLogin()
        try Task.checkCancellation()
        try await vault.save(StoredToken(value: token, kind: kind, login: login))
        logger.info("Angemeldet (\(kind.rawValue, privacy: .public))")
        await engine.reset()
        syncState = nil
        auth = .signedIn(login: login, kind: kind)
        await scheduler.start(with: .launch)
    }

    /// Kopiert den Code und öffnet die Bestätigungsseite von GitHub.
    public func copyCodeAndOpenVerificationPage() {
        guard case .awaitingDeviceConfirmation(let authorization) = auth else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(authorization.userCode, forType: .string)
        NSWorkspace.shared.open(authorization.verificationURL)
    }

    // MARK: Abmelden

    /// Löscht Token, Cache und „Gesehen“-Stand (Konzept 11).
    public func signOut(message: String? = nil) {
        signInTask?.cancel()
        syncState = nil
        isSyncing = false
        lastError = nil
        lastChanges = nil
        auth = .signedOut(message: message)
        seenState = SeenState()
        ui.seen = seenState
        try? seenStore.clear()
        Task {
            await scheduler.stop()
            await engine.reset()
            do {
                try await vault.clear()
                logger.info("Abgemeldet")
            } catch {
                logger.error("Token konnte nicht gelöscht werden: \(error.localizedDescription, privacy: .public)")
                auth = .signedOut(message: error.localizedDescription)
            }
        }
    }

    // MARK: Aktualisieren

    /// ⌘R bzw. „Aktualisieren“: alles sofort.
    public func refresh() {
        guard isSignedIn else { return }
        Task { await scheduler.trigger(.manual) }
    }

    /// Panel geöffnet: aktive Repos mit älteren Daten nachladen, „gesehen“ merken.
    public func panelDidOpen() {
        guard isSignedIn else { return }
        Task { await scheduler.trigger(.panelOpened) }
    }

    /// Panel geschlossen: Ab jetzt gilt alles Neue als „neu seit dem letzten Öffnen“.
    public func panelDidClose() {
        guard isSignedIn else { return }
        seenState.panelOpenedAt = Date()
        saveSeenState()
    }

    /// Repo als gesehen markieren (Kontextmenü, Detailansicht).
    public func markSeen(_ repositoryID: String) {
        seenState.repositorySeenAt[repositoryID] = Date()
        saveSeenState()
    }

    private func saveSeenState() {
        ui.seen = seenState
        do {
            try seenStore.save(seenState)
        } catch {
            logger.error("Gesehen-Stand nicht gespeichert: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: Einstellungen

    public func toggleFavorite(_ nameWithOwner: String) {
        updateSettings { settings in
            if let index = settings.favorites.firstIndex(of: nameWithOwner) {
                settings.favorites.remove(at: index)
            } else {
                settings.favorites.append(nameWithOwner)
            }
        }
    }

    /// Ändert Einstellungen, speichert sie und gibt sie an Sync und Module weiter.
    public func updateSettings(_ change: (inout AppSettings) -> Void) {
        let old = settings
        var new = settings
        change(&new)
        guard new != old else { return }
        settings = new
        ui.settings = new
        settingsStore.save(new)

        var needsResync = false
        if Self.filter(from: new) != Self.filter(from: old) { needsResync = true }
        if new.authorRules != old.authorRules {
            authorRules.value = new.authorRules
            needsResync = true
        }
        if new.actionsHiddenEvents != old.actionsHiddenEvents {
            // Wirkt auf den Alarm erst nach der nächsten Zusammenfassung, also nach einem Sync.
            ignoredWorkflowEvents.value = Set(new.actionsHiddenEvents)
            needsResync = true
        }
        let modulesChanged = new.disabledModules != old.disabledModules
        needsResync = needsResync || modulesChanged
        let favoritesChanged = new.favorites != old.favorites
        let policyChanged = Self.policy(from: new) != Self.policy(from: old)

        Task {
            if Self.filter(from: new) != Self.filter(from: old) {
                await engine.updateFilter(Self.filter(from: new))
            }
            if modulesChanged {
                for module in moduleUIs {
                    await engine.setModule(module.moduleID, enabled: new.isEnabled(module.moduleID))
                }
            }
            if favoritesChanged { await scheduler.setFavorites(Set(new.favorites)) }
            if policyChanged { await scheduler.setPolicy(Self.policy(from: new)) }
            if needsResync && isSignedIn { await scheduler.trigger(.manual) }
        }
    }

    public var enabledModuleUIs: [any ModuleUI] {
        moduleUIs.filter { settings.isEnabled($0.moduleID) }
    }

    static func filter(from settings: AppSettings) -> SyncFilter {
        SyncFilter(
            includeArchived: settings.includeArchived,
            includeForks: settings.includeForks,
            excludedOwners: Set(settings.excludedOwners),
            excludedPatterns: settings.excludedPatterns
        )
    }

    static func policy(from settings: AppSettings) -> RefreshPolicy {
        var policy = RefreshPolicy()
        policy.activeInterval = TimeInterval(max(1, settings.activeIntervalMinutes) * 60)
        policy.dormantInterval = TimeInterval(max(5, settings.dormantIntervalMinutes) * 60)
        return policy
    }

    #if DEBUG
    /// Nur für SwiftUI-Previews: festen Stand anzeigen, ohne Token und ohne Sync.
    public func loadPreview(_ state: SyncState) {
        auth = .signedIn(login: state.viewerLogin, kind: .personalAccessToken)
        syncState = state
    }
    #endif

    // MARK: Gesperrte Organisationen

    /// Organisationen, die RepoWatch per OAuth-Zugriffsbeschränkung sperren (Konzept 5).
    public var restrictedOrganizations: [String] {
        syncState?.restrictedOrganizations ?? []
    }

    /// Wo sich der Zugriff anfragen lässt: bei OAuth die App-Seite in den GitHub-Einstellungen
    /// (dort „Request“/„Grant“ je Organisation), sonst die Erklärung von GitHub.
    public var accessRequestURL: URL {
        if case .signedIn(_, .oauth) = auth, let oauthClientID,
           let url = URL(string: "https://github.com/settings/connections/applications/\(oauthClientID)") {
            return url
        }
        return URL(string: "https://docs.github.com/en/organizations/managing-oauth-access-to-your-organizations-data/about-oauth-app-access-restrictions")!
    }

    // MARK: Neu und Menüleiste

    /// Gibt es in diesem Repo etwas seit dem letzten Blick? (Konzept 3.2)
    public func hasNews(_ repository: RepoSnapshot) -> Bool {
        guard let since = ui.newSince(repositoryID: repository.id) else { return false }
        if let pushed = repository.meta.pushedAt, pushed > since { return true }
        return enabledModuleUIs.contains { $0.hasNews(in: repository, since: since) }
    }

    /// Anzeige in der Menüleiste (Konzept 3.1, E7).
    public var menuBarIndicator: MenuBarIndicator {
        let repositories = repositories
        let alarm = settings.alarmDotEnabled && repositories.contains { repository in
            repository.summaries.contains { settings.isEnabled($0.key) && $0.value.needsAttention }
        }
        let count: Int? = switch settings.menuBarMode {
        case .personPullRequests:
            repositories.reduce(0) { total, repository in
                let counts = repository.summaries[ModuleID("prs")]?.counts ?? [:]
                return total + (counts["human"] ?? 0) + (counts["me"] ?? 0)
            }
        case .openItems:
            repositories.reduce(0) { $0 + $1.meta.openIssueCount + $1.meta.openPullRequestCount }
        case .none, .newItemsDot:
            nil
        }
        let showsNew = settings.menuBarMode == .newItemsDot && repositories.contains(where: hasNews)
        return MenuBarIndicator(count: count, showsNewDot: showsNew, showsAlarm: alarm)
    }

    private func systemDidWake() {
        guard isSignedIn else { return }
        Task { await scheduler.trigger(.wake) }
    }

    private func handle(_ event: SyncEvent) {
        guard isSignedIn else { return }
        switch event {
        case .started:
            isSyncing = true
        case .finished(let outcome):
            isSyncing = false
            lastError = nil
            nextRetryAt = nil
            syncState = outcome.state
            if !outcome.changes.isEmpty { lastChanges = outcome.changes }
            if case .signedIn(let login, let kind) = auth, login != outcome.state.viewerLogin, !outcome.state.viewerLogin.isEmpty {
                auth = .signedIn(login: outcome.state.viewerLogin, kind: kind)
            }
        case .failed(.unauthorized, _):
            logger.error("Token abgelehnt, melde ab")
            signOut(message: String(localized: "GitHub hat das Token nicht mehr akzeptiert. Bitte neu anmelden."))
        case .failed(let error, let retryAt):
            isSyncing = false
            lastError = error.localizedDescription
            nextRetryAt = retryAt
        }
    }
}
