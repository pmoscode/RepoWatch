import Auth

extension StoredToken.Kind {
    var displayName: String {
        switch self {
        case .oauth: String(localized: "Angemeldet über GitHub (OAuth)")
        case .personalAccessToken: String(localized: "Personal Access Token")
        case .environment: String(localized: "Token aus GITHUB_TOKEN (Debug)")
        }
    }
}
