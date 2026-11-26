import AppKit
import Auth
import Domain
import Foundation
import GitHubAPI
import ModuleKit
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
    /// Registrierte Module (Konzept 9.2), Standard: `ModuleRegistry.standard()`.
    public var modules: ModuleRegistry
    public var sync: SyncConfiguration

    public init(
        oauthClientID: String?,
        tokenStore: any TokenStore,
        environmentToken: StoredToken? = nil,
        snapshotStore: (any SnapshotStore)? = nil,
        seenStateStore: any SeenStateStore = InMemorySeenStateStore(),
        modules: ModuleRegistry = ModuleRegistry(),
        sync: SyncConfiguration = SyncConfiguration()
    ) {
        self.oauthClientID = oauthClientID
        self.tokenStore = tokenStore
        self.environmentToken = environmentToken
        self.snapshotStore = snapshotStore
        self.seenStateStore = seenStateStore
        self.modules = modules
        self.sync = sync
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
        let modules: ModuleRegistry
        do {
            modules = try .standard()
        } catch {
            // Kann nur bei einem fehlerhaften Fragment passieren; Tests verhindern das.
            assertionFailure("Module nicht registrierbar: \(error)")
            modules = ModuleRegistry()
        }
        return AppConfiguration(
            oauthClientID: isConfigured ? clientID : nil,
            tokenStore: KeychainTokenStore(),
            environmentToken: allowEnvironmentToken ? EnvironmentToken.read() : nil,
            snapshotStore: snapshotURL.map(JSONFileSnapshotStore.init(fileURL:)),
            seenStateStore: seenURL.map { JSONFileSeenStateStore(fileURL: $0) as any SeenStateStore }
                ?? InMemorySeenStateStore(),
            modules: modules
        )
    }
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
    public private(set) var syncState: SyncState?
    public private(set) var isSyncing = false
    /// Fehler des letzten Durchlaufs; die alten Daten bleiben sichtbar.
    public private(set) var lastError: String?
    public private(set) var nextRetryAt: Date?
    public private(set) var lastChanges: ChangeSet?
    public private(set) var seenState = SeenState()
    public var isDeviceFlowAvailable: Bool { deviceFlow != nil }

    private let vault: TokenVault
    private let engine: SyncEngine
    private let scheduler: RefreshScheduler
    private let deviceFlow: DeviceFlowAuthenticator?
    private let seenStore: any SeenStateStore
    private var signInTask: Task<Void, Never>?
    private var eventsTask: Task<Void, Never>?
    private var systemEvents: SystemEventsMonitor?
    private let logger = Logger(subsystem: "de.pmoscode.repowatch", category: "AppModel")

    public init(configuration: AppConfiguration) {
        vault = TokenVault(store: configuration.tokenStore, environmentToken: configuration.environmentToken)
        let transport = HTTPTransport(tokenProvider: vault)
        engine = SyncEngine(
            client: GraphQLClient(transport: transport),
            rest: RESTClient(transport: transport),
            registry: configuration.modules,
            configuration: configuration.sync,
            store: configuration.snapshotStore
        )
        scheduler = RefreshScheduler(engine: engine)
        deviceFlow = configuration.oauthClientID.map { DeviceFlowAuthenticator(clientID: $0) }
        seenStore = configuration.seenStateStore
        seenState = (try? seenStore.load()) ?? SeenState()

        eventsTask = Task { [weak self, events = scheduler.events] in
            for await event in events {
                self?.handle(event)
            }
        }
        systemEvents = SystemEventsMonitor { [weak self] in
            self?.systemDidWake()
        }
    }

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
        do {
            try seenStore.save(seenState)
        } catch {
            logger.error("Gesehen-Stand nicht gespeichert: \(error.localizedDescription, privacy: .public)")
        }
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
