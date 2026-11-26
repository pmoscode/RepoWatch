import Foundation

/// Wer etwas erstellt hat (Konzept 6). Gilt für PRs und für Workflow-Runs aus PRs.
public enum AuthorKind: Codable, Hashable, Sendable {
    case renovate
    case dependabot
    /// Anderer Bot, z. B. `github-actions`.
    case bot(name: String)
    /// Der angemeldete Benutzer.
    case me
    case human(login: String)

    public enum Category: String, Codable, Sendable, CaseIterable {
        case human, me, renovate, dependabot, otherBot
    }

    public var category: Category {
        switch self {
        case .renovate: .renovate
        case .dependabot: .dependabot
        case .bot: .otherBot
        case .me: .me
        case .human: .human
        }
    }

    /// Menschen und ich: Hier wartet meist eine Review oder Arbeit (Konzept 3.2, E7).
    public var isPerson: Bool {
        switch self {
        case .me, .human: true
        default: false
        }
    }
}

/// Was über einen Autor bekannt ist.
public struct AuthorInput: Sendable, Equatable {
    public var login: String?
    /// GraphQL-`__typename` (`User`, `Bot`, `Mannequin` …); in REST unbekannt.
    public var typeName: String?
    /// Branch des PRs, z. B. `renovate/swift-6.x`.
    public var branch: String?

    public init(login: String?, typeName: String? = nil, branch: String? = nil) {
        self.login = login
        self.typeName = typeName
        self.branch = branch
    }
}

/// Einstellbare Teile der Regelkette (Konzept 3.3, Reiter „Pull Requests“).
public struct AuthorRules: Codable, Sendable, Equatable {
    /// GraphQL liefert Bot-Logins ohne `[bot]`, REST mit (Konzept 4.3) – daher beide Schreibweisen.
    public var renovateLogins: Set<String>
    public var dependabotLogins: Set<String>
    public var renovateBranchPrefixes: [String]
    public var dependabotBranchPrefixes: [String]

    public init(
        renovateLogins: Set<String> = ["renovate", "renovate[bot]"],
        dependabotLogins: Set<String> = ["dependabot", "dependabot[bot]"],
        renovateBranchPrefixes: [String] = ["renovate/"],
        dependabotBranchPrefixes: [String] = ["dependabot/"]
    ) {
        self.renovateLogins = renovateLogins
        self.dependabotLogins = dependabotLogins
        self.renovateBranchPrefixes = renovateBranchPrefixes
        self.dependabotBranchPrefixes = dependabotBranchPrefixes
    }

    public static let `default` = AuthorRules()
}

/// Eine Regel der Kette; `nil` heißt „weiß ich nicht, nächste Regel“.
public protocol AuthorClassificationRule: Sendable {
    func classify(_ input: AuthorInput, viewerLogin: String) -> AuthorKind?
}

/// Geordnete Regelkette, die erste passende Regel gewinnt (Konzept 6).
public struct AuthorClassifier: Sendable {
    public let rules: [any AuthorClassificationRule]

    public init(rules: [any AuthorClassificationRule]) {
        self.rules = rules
    }

    /// Die Standardkette: Login-Liste → Branch-Präfix → Bot → ich → Mensch.
    public static func standard(_ settings: AuthorRules = .default) -> AuthorClassifier {
        AuthorClassifier(rules: [
            LoginListRule(settings: settings),
            BranchPrefixRule(settings: settings),
            BotRule(),
            ViewerRule(),
        ])
    }

    public func classify(_ input: AuthorInput, viewerLogin: String) -> AuthorKind {
        for rule in rules {
            if let kind = rule.classify(input, viewerLogin: viewerLogin) { return kind }
        }
        return .human(login: input.login ?? "ghost")
    }
}

// MARK: - Regeln

/// 1. Bekannte Logins (inkl. selbst betriebener Renovate-Instanz).
public struct LoginListRule: AuthorClassificationRule {
    let settings: AuthorRules
    public func classify(_ input: AuthorInput, viewerLogin: String) -> AuthorKind? {
        guard let login = input.login?.lowercased() else { return nil }
        if settings.renovateLogins.contains(where: { $0.lowercased() == login }) { return .renovate }
        if settings.dependabotLogins.contains(where: { $0.lowercased() == login }) { return .dependabot }
        return nil
    }
}

/// 2. Branch-Präfix, z. B. `renovate/…`.
public struct BranchPrefixRule: AuthorClassificationRule {
    let settings: AuthorRules
    public func classify(_ input: AuthorInput, viewerLogin: String) -> AuthorKind? {
        guard let branch = input.branch else { return nil }
        if settings.renovateBranchPrefixes.contains(where: branch.hasPrefix) { return .renovate }
        if settings.dependabotBranchPrefixes.contains(where: branch.hasPrefix) { return .dependabot }
        return nil
    }
}

/// 3. `__typename == "Bot"` oder Login endet auf `[bot]`.
public struct BotRule: AuthorClassificationRule {
    public func classify(_ input: AuthorInput, viewerLogin: String) -> AuthorKind? {
        let login = input.login ?? ""
        if input.typeName == "Bot" || login.hasSuffix("[bot]") {
            let name = login.hasSuffix("[bot]") ? String(login.dropLast(5)) : login
            return .bot(name: name.isEmpty ? "bot" : name)
        }
        return nil
    }
}

/// 4. Der angemeldete Benutzer.
public struct ViewerRule: AuthorClassificationRule {
    public func classify(_ input: AuthorInput, viewerLogin: String) -> AuthorKind? {
        guard let login = input.login, !viewerLogin.isEmpty,
              login.caseInsensitiveCompare(viewerLogin) == .orderedSame else { return nil }
        return .me
    }
}

// MARK: - CI-Status

/// Zusammengefasster Status von Checks (`statusCheckRollup`).
public enum CIState: String, Codable, Sendable, Hashable {
    case success, failure, pending

    /// Aus GraphQL `StatusState`: SUCCESS, FAILURE, ERROR, PENDING, EXPECTED.
    public init?(graphQL value: String?) {
        switch value?.uppercased() {
        case "SUCCESS": self = .success
        case "FAILURE", "ERROR": self = .failure
        case "PENDING", "EXPECTED": self = .pending
        default: return nil
        }
    }
}
