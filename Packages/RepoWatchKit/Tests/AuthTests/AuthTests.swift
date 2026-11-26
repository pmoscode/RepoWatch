import Foundation
import Testing
import TestSupport
@testable import Auth
@testable import GitHubAPI

@Suite("Device Flow")
struct DeviceFlowTests {
    private func authorization(expiresIn: TimeInterval = 900) -> DeviceAuthorization {
        DeviceAuthorization(
            deviceCode: "dev-123", userCode: "ABCD-1234",
            verificationURL: URL(string: "https://github.com/login/device")!,
            expiresAt: Date().addingTimeInterval(expiresIn), interval: .seconds(5)
        )
    }

    /// Authenticator gegen einen Mock, der die Token-Antworten der Reihe nach liefert.
    private func makeAuthenticator(
        sleeper: SleepRecorder,
        tokenResponses: [String]
    ) -> (DeviceFlowAuthenticator, Locked<[URLRequest]>) {
        let requests = Locked<[URLRequest]>([])
        let (session, baseURL) = MockURLProtocol.makeSession { request in
            let index = requests.withLock { list -> Int in
                list.append(request)
                return list.count - 1
            }
            let body = tokenResponses[min(index, tokenResponses.count - 1)]
            return (.make(200, for: request), Data(body.utf8))
        }
        let authenticator = DeviceFlowAuthenticator(
            clientID: "client-xyz", baseURL: baseURL, session: session, sleep: sleeper.sleeper
        )
        return (authenticator, requests)
    }

    @Test("Start: Code wird angefordert und gelesen")
    func start() async throws {
        let sent = Locked<URLRequest?>(nil)
        let (session, baseURL) = MockURLProtocol.makeSession { request in
            sent.withLock { $0 = request }
            let body = #"{"device_code":"dev-123","user_code":"ABCD-1234","verification_uri":"https://github.com/login/device","expires_in":900,"interval":5}"#
            return (.make(200, for: request), Data(body.utf8))
        }
        let authenticator = DeviceFlowAuthenticator(clientID: "client-xyz", baseURL: baseURL, session: session)

        let result = try await authenticator.start()

        #expect(result.userCode == "ABCD-1234")
        #expect(result.deviceCode == "dev-123")
        #expect(result.interval == .seconds(5))
        let request = try #require(sent.value)
        #expect(request.url?.path() == "/login/device/code")
        #expect(request.value(forHTTPHeaderField: "Accept") == "application/json")
        #expect(request.formFields["client_id"] == "client-xyz")
        #expect(request.formFields["scope"] == "repo read:org")
    }

    @Test("Warten: pending → slow_down → Token, Abstand wird vergrößert")
    func pollsUntilToken() async throws {
        let sleeper = SleepRecorder()
        let (authenticator, requests) = makeAuthenticator(sleeper: sleeper, tokenResponses: [
            #"{"error":"authorization_pending"}"#,
            #"{"error":"slow_down","interval":10}"#,
            #"{"access_token":"gho_secret","token_type":"bearer","scope":"repo,read:org"}"#,
        ])

        let token = try await authenticator.waitForToken(authorization())

        #expect(token == "gho_secret")
        #expect(sleeper.durations == [.seconds(5), .seconds(5), .seconds(10)])
        let last = try #require(requests.value.last)
        #expect(last.url?.path() == "/login/oauth/access_token")
        #expect(last.formFields["device_code"] == "dev-123")
        #expect(last.formFields["grant_type"] == "urn:ietf:params:oauth:grant-type:device_code")
    }

    @Test("Abgelaufen und abgelehnt werden gemeldet")
    func terminalErrors() async {
        let (expiredFlow, _) = makeAuthenticator(sleeper: SleepRecorder(), tokenResponses: [#"{"error":"expired_token"}"#])
        await #expect(throws: DeviceFlowError.expired) { _ = try await expiredFlow.waitForToken(authorization()) }

        let (deniedFlow, _) = makeAuthenticator(sleeper: SleepRecorder(), tokenResponses: [#"{"error":"access_denied"}"#])
        await #expect(throws: DeviceFlowError.denied) { _ = try await deniedFlow.waitForToken(authorization()) }
    }

    @Test("Abgelaufener Code: keine Anfrage mehr")
    func expiredLocally() async {
        let (flow, requests) = makeAuthenticator(sleeper: SleepRecorder(), tokenResponses: [#"{"error":"authorization_pending"}"#])
        await #expect(throws: DeviceFlowError.expired) { _ = try await flow.waitForToken(authorization(expiresIn: -1)) }
        #expect(requests.value.isEmpty)
    }

    @Test("Unbekannte Client-ID (404) → .invalidClient")
    func invalidClient() async {
        let (session, baseURL) = MockURLProtocol.makeSession { (.make(404, for: $0), Data("Not Found".utf8)) }
        let flow = DeviceFlowAuthenticator(clientID: "nope", baseURL: baseURL, session: session)
        await #expect(throws: DeviceFlowError.invalidClient) { _ = try await flow.start() }
    }

    @Test("Formular-Kodierung escaped Leerzeichen und Doppelpunkte")
    func formEncoding() {
        let body = String(decoding: DeviceFlowAuthenticator.formEncode(["scope": "repo read:org", "a": "1"]), as: UTF8.self)
        #expect(body == "a=1&scope=repo%20read%3Aorg")
    }
}

@Suite("Token-Tresor")
struct TokenVaultTests {
    @Test("Speichern, Lesen, Löschen")
    func roundTrip() async throws {
        let store = InMemoryTokenStore()
        let vault = TokenVault(store: store)
        #expect(try await vault.current() == nil)
        await #expect(throws: GitHubAPIError.missingToken) { _ = try await vault.token() }

        let token = StoredToken(value: "abc", kind: .oauth, login: "octo")
        try await vault.save(token)
        #expect(try await vault.token() == "abc")
        #expect(try store.load() == token)

        try await vault.clear()
        #expect(try await vault.current() == nil)
        #expect(try store.load() == nil)
    }

    @Test("Umgebungs-Token hat Vorrang und wird beim Abmelden vergessen")
    func environmentOverride() async throws {
        let stored = StoredToken(value: "stored", kind: .personalAccessToken, login: nil)
        let vault = TokenVault(
            store: InMemoryTokenStore(stored),
            environmentToken: StoredToken(value: "env", kind: .environment, login: nil)
        )
        #expect(try await vault.token() == "env")
        try await vault.clear()
        #expect(try await vault.current() == nil)
    }

    @Test("Liest den Speicher nur einmal")
    func loadsOnce() async throws {
        let store = InMemoryTokenStore(StoredToken(value: "a", kind: .oauth, login: nil))
        let vault = TokenVault(store: store)
        #expect(try await vault.token() == "a")
        try store.save(StoredToken(value: "b", kind: .oauth, login: nil))
        #expect(try await vault.token() == "a")
    }
}

@Suite("Schlüsselbund", .enabled(if: ProcessInfo.processInfo.environment["CI"] == nil, "braucht einen entsperrten Schlüsselbund"))
struct KeychainTokenStoreTests {
    @Test("Eintrag anlegen, überschreiben, lesen, löschen")
    func roundTrip() throws {
        let store = KeychainTokenStore(service: "de.pmoscode.repowatch.tests.\(UUID().uuidString)", account: "test")
        defer { try? store.delete() }

        #expect(try store.load() == nil)
        try store.save(StoredToken(value: "one", kind: .oauth, login: "a"))
        try store.save(StoredToken(value: "two", kind: .personalAccessToken, login: "b"))
        #expect(try store.load() == StoredToken(value: "two", kind: .personalAccessToken, login: "b"))
        try store.delete()
        #expect(try store.load() == nil)
        try store.delete()
    }
}
