import AppKit
import Auth
import Domain
import Foundation
import GitHubAPI
import Observation
import Sync
import os

/// Einstellungen, die die App beim Start mitgibt.
public struct AppConfiguration: Sendable {
    /// Client-ID der OAuth-App für den Device Flow; `nil`, solange keine hinterlegt ist.
    public var oauthClientID: String?
    public var tokenStore: any TokenStore
    /// Nur Debug-Builds: `GITHUB_TOKEN` hat Vorrang vor dem Schlüsselbund.
    public var environmentToken: StoredToken?

    public init(oauthClientID: String?, tokenStore: any TokenStore, environmentToken: StoredToken? = nil) {
        self.oauthClientID = oauthClientID
        self.tokenStore = tokenStore
        self.environmentToken = environmentToken
    }

    /// Konfiguration der laufenden App: Schlüsselbund, Client-ID aus der Info.plist und in
    /// Debug-Builds optional `GITHUB_TOKEN`. So muss die App-Schicht `Auth` nicht kennen.
    public static func live(bundle: Bundle = .main, allowEnvironmentToken: Bool) -> AppConfiguration {
        let clientID = (bundle.object(forInfoDictionaryKey: "GitHubOAuthClientID") as? String)?
            .trimmingCharacters(in: .whitespaces)
        let isConfigured = clientID.map { !$0.isEmpty && !$0.hasPrefix("$(") } ?? false
        return AppConfiguration(
            oauthClientID: isConfigured ? clientID : nil,
            tokenStore: KeychainTokenStore(),
            environmentToken: allowEnvironmentToken ? EnvironmentToken.read() : nil
        )
    }
}

/// Zentraler UI-Zustand (Konzept 9.3): Anmeldung und Bestand.
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

    public enum LoadState: Equatable {
        case idle
        case loading
        case loaded
        case failed(String)
    }

    public private(set) var auth: AuthState = .checking
    public private(set) var state: LoadState = .idle
    public private(set) var inventory: InventorySnapshot?
    public var isDeviceFlowAvailable: Bool { deviceFlow != nil }

    private let vault: TokenVault
    private let transport: HTTPTransport
    private let fetcher: InventoryFetcher
    private let deviceFlow: DeviceFlowAuthenticator?
    private var refreshTask: Task<Void, Never>?
    private var signInTask: Task<Void, Never>?
    private let logger = Logger(subsystem: "de.pmoscode.repowatch", category: "AppModel")

    public init(configuration: AppConfiguration) {
        vault = TokenVault(store: configuration.tokenStore, environmentToken: configuration.environmentToken)
        transport = HTTPTransport(tokenProvider: vault)
        fetcher = InventoryFetcher(client: GraphQLClient(transport: transport))
        deviceFlow = configuration.oauthClientID.map { DeviceFlowAuthenticator(clientID: $0) }
    }

    public var isSignedIn: Bool {
        if case .signedIn = auth { true } else { false }
    }

    public var visibleRepositories: [RepoMeta] {
        (inventory?.repositories ?? []).filter { !$0.isArchived }
    }

    // MARK: Start

    /// Liest das gespeicherte Token und lädt bei Erfolg den Bestand.
    public func start() {
        Task {
            do {
                if let token = try await vault.current() {
                    auth = .signedIn(login: token.login ?? "", kind: token.kind)
                    refresh()
                } else {
                    auth = .signedOut(message: nil)
                }
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

    /// Prüft das Token mit `viewer { login }`, speichert es und lädt den Bestand.
    private func completeSignIn(token: String, kind: StoredToken.Kind) async throws {
        auth = .validating
        let probe = GraphQLClient(transport: HTTPTransport(tokenProvider: StaticTokenProvider(token), retryPolicy: .none))
        let login = try await probe.viewerLogin()
        try Task.checkCancellation()
        try await vault.save(StoredToken(value: token, kind: kind, login: login))
        logger.info("Angemeldet (\(kind.rawValue, privacy: .public))")
        auth = .signedIn(login: login, kind: kind)
        refresh()
    }

    /// Kopiert den Code und öffnet die Bestätigungsseite von GitHub.
    public func copyCodeAndOpenVerificationPage() {
        guard case .awaitingDeviceConfirmation(let authorization) = auth else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(authorization.userCode, forType: .string)
        NSWorkspace.shared.open(authorization.verificationURL)
    }

    // MARK: Abmelden

    public func signOut(message: String? = nil) {
        signInTask?.cancel()
        refreshTask?.cancel()
        inventory = nil
        state = .idle
        auth = .signedOut(message: message)
        Task {
            do {
                try await vault.clear()
                logger.info("Abgemeldet")
            } catch {
                logger.error("Token konnte nicht gelöscht werden: \(error.localizedDescription, privacy: .public)")
                auth = .signedOut(message: error.localizedDescription)
            }
        }
    }

    // MARK: Laden

    public func refresh() {
        guard isSignedIn else { return }
        refreshTask?.cancel()
        state = .loading
        refreshTask = Task { [fetcher, logger] in
            do {
                let snapshot = try await fetcher.fetchAll()
                guard !Task.isCancelled else { return }
                logger.info(
                    "Bestand geladen: \(snapshot.repositories.count) Repos, \(snapshot.pageCount) Seite(n), Kosten \(snapshot.totalCost)"
                )
                inventory = snapshot
                state = .loaded
                if case .signedIn(let login, let kind) = auth, login != snapshot.viewerLogin {
                    auth = .signedIn(login: snapshot.viewerLogin, kind: kind)
                }
            } catch is CancellationError {
                return
            } catch GitHubAPIError.unauthorized {
                guard !Task.isCancelled else { return }
                logger.error("Token abgelehnt, melde ab")
                signOut(message: String(localized: "GitHub hat das Token nicht mehr akzeptiert. Bitte neu anmelden."))
            } catch {
                guard !Task.isCancelled else { return }
                logger.error("Bestand fehlgeschlagen: \(error.localizedDescription, privacy: .public)")
                state = .failed(error.localizedDescription)
            }
        }
    }
}
