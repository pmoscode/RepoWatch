import Foundation
import GitHubAPI

/// Ergebnis des ersten Device-Flow-Schritts: Code, den der Nutzer auf GitHub eingibt.
public struct DeviceAuthorization: Sendable, Equatable {
    public let deviceCode: String
    public let userCode: String
    public let verificationURL: URL
    public let expiresAt: Date
    public let interval: Duration

    public init(deviceCode: String, userCode: String, verificationURL: URL, expiresAt: Date, interval: Duration) {
        self.deviceCode = deviceCode
        self.userCode = userCode
        self.verificationURL = verificationURL
        self.expiresAt = expiresAt
        self.interval = interval
    }
}

public enum DeviceFlowError: Error, Sendable, Equatable, LocalizedError {
    /// Der Code ist abgelaufen, bevor er bestätigt wurde.
    case expired
    /// Der Nutzer hat die Anmeldung auf GitHub abgelehnt.
    case denied
    /// In der OAuth-App ist „Enable Device Flow“ nicht angehakt.
    case disabledForApp
    /// Client-ID unbekannt oder falsch.
    case invalidClient
    case unexpected(String)
    case transport(String)

    public var errorDescription: String? {
        switch self {
        case .expired: String(localized: "Der Code ist abgelaufen. Bitte erneut anmelden.")
        case .denied: String(localized: "Die Anmeldung wurde auf GitHub abgelehnt.")
        case .disabledForApp: String(localized: "In der OAuth-App ist der Device Flow nicht aktiviert.")
        case .invalidClient: String(localized: "Die Client-ID der OAuth-App ist ungültig.")
        case .unexpected(let detail): String(localized: "Unerwartete Antwort von GitHub: \(detail)")
        case .transport(let detail): String(localized: "Netzwerkfehler: \(detail)")
        }
    }
}

/// OAuth Device Flow (Konzept 5): Code anzeigen → Nutzer bestätigt im Browser → Token abholen.
/// Kommt ohne Client-Secret aus; die Client-ID ist öffentlich.
public struct DeviceFlowAuthenticator: Sendable {
    public static let defaultScopes = ["repo", "read:org"]

    private let clientID: String
    private let scopes: [String]
    private let baseURL: URL
    private let session: URLSession
    private let sleep: Sleeper
    private let now: @Sendable () -> Date

    public init(
        clientID: String,
        scopes: [String] = DeviceFlowAuthenticator.defaultScopes,
        baseURL: URL = URL(string: "https://github.com")!,
        session: URLSession = HTTPTransport.makeSession(),
        sleep: @escaping Sleeper = { try await Task.sleep(for: $0) },
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.clientID = clientID
        self.scopes = scopes
        self.baseURL = baseURL
        self.session = session
        self.sleep = sleep
        self.now = now
    }

    /// Schritt 1: Gerätecode und Benutzercode anfordern.
    public func start() async throws -> DeviceAuthorization {
        let response: CodeResponse = try await post(
            "login/device/code",
            form: ["client_id": clientID, "scope": scopes.joined(separator: " ")]
        )
        if let error = response.error {
            throw Self.map(error: error)
        }
        guard let deviceCode = response.deviceCode,
              let userCode = response.userCode,
              let uri = response.verificationUri.flatMap(URL.init(string:)),
              let expiresIn = response.expiresIn
        else {
            throw DeviceFlowError.unexpected("unvollständige Antwort")
        }
        return DeviceAuthorization(
            deviceCode: deviceCode,
            userCode: userCode,
            verificationURL: uri,
            expiresAt: now().addingTimeInterval(TimeInterval(expiresIn)),
            interval: .seconds(response.interval ?? 5)
        )
    }

    /// Schritt 2: Im vorgegebenen Abstand fragen, bis der Nutzer bestätigt hat. Abbrechbar über `Task.cancel()`.
    public func waitForToken(_ authorization: DeviceAuthorization) async throws -> String {
        var interval = authorization.interval
        while true {
            try Task.checkCancellation()
            guard now() < authorization.expiresAt else { throw DeviceFlowError.expired }
            try await sleep(interval)

            let response: TokenResponse = try await post(
                "login/oauth/access_token",
                form: [
                    "client_id": clientID,
                    "device_code": authorization.deviceCode,
                    "grant_type": "urn:ietf:params:oauth:grant-type:device_code",
                ]
            )
            if let token = response.accessToken, !token.isEmpty {
                return token
            }
            switch response.error {
            case "authorization_pending":
                continue
            case "slow_down":
                // GitHub verlangt einen größeren Abstand und nennt ihn meist gleich mit.
                interval = response.interval.map { .seconds($0) } ?? interval + .seconds(5)
            case let error?:
                throw Self.map(error: error)
            case nil:
                throw DeviceFlowError.unexpected("weder Token noch Fehler")
            }
        }
    }

    // MARK: Hilfen

    static func map(error: String) -> DeviceFlowError {
        switch error {
        case "expired_token": .expired
        case "access_denied": .denied
        case "device_flow_disabled": .disabledForApp
        case "incorrect_client_credentials", "unauthorized_client": .invalidClient
        default: .unexpected(error)
        }
    }

    private func post<Response: Decodable>(_ path: String, form: [String: String]) async throws -> Response {
        var request = URLRequest(url: baseURL.appending(path: path))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("RepoWatch", forHTTPHeaderField: "User-Agent")
        request.httpBody = Self.formEncode(form)

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
        } catch {
            throw DeviceFlowError.transport(error.localizedDescription)
        }
        if let http = response as? HTTPURLResponse, http.statusCode == 404 {
            // GitHub antwortet bei unbekannter Client-ID mit 404.
            throw DeviceFlowError.invalidClient
        }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        do {
            return try decoder.decode(Response.self, from: data)
        } catch {
            throw DeviceFlowError.unexpected(String(decoding: data.prefix(200), as: UTF8.self))
        }
    }

    static func formEncode(_ form: [String: String]) -> Data {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        let body = form
            .sorted { $0.key < $1.key }
            .map { key, value in
                "\(key)=\(value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value)"
            }
            .joined(separator: "&")
        return Data(body.utf8)
    }

    private struct CodeResponse: Decodable {
        let deviceCode: String?
        let userCode: String?
        let verificationUri: String?
        let expiresIn: Int?
        let interval: Int?
        let error: String?
    }

    private struct TokenResponse: Decodable {
        let accessToken: String?
        let error: String?
        let interval: Int?
    }
}
