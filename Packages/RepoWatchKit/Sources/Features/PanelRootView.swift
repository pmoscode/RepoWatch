import DesignSystem
import Domain
import SwiftUI

/// Inhalt des Menüleisten-Panels: Anmeldung oder Bestand als einfache Liste.
public struct PanelRootView: View {
    private let model: AppModel
    private let onQuit: () -> Void

    public init(model: AppModel, onQuit: @escaping () -> Void) {
        self.model = model
        self.onQuit = onQuit
    }

    public var body: some View {
        VStack(spacing: 0) {
            if model.isSignedIn {
                header
                Divider()
                content
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                SignInView(model: model)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            Divider()
            footer
        }
        .frame(width: 400, height: 560)
    }

    // MARK: Kopf

    private var header: some View {
        HStack(spacing: 8) {
            accountMenu
            Spacer()
            if model.isSyncing {
                ProgressView()
                    .controlSize(.small)
                    .help("Wird aktualisiert …")
            }
            Button {
                model.refresh()
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.borderless)
            .keyboardShortcut("r")
            .help("Aktualisieren (⌘R)")
            .disabled(model.isSyncing)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private var accountMenu: some View {
        Menu {
            if case .signedIn(_, let kind) = model.auth {
                Text(kind.displayName)
            }
            Divider()
            Button("Abmelden", systemImage: "rectangle.portrait.and.arrow.right", role: .destructive) {
                model.signOut()
            }
        } label: {
            Label {
                Text(login)
                    .font(.headline)
            } icon: {
                Image(systemName: "person.crop.circle")
                    .foregroundStyle(.secondary)
            }
            .labelStyle(.titleAndIcon)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Konto")
    }

    private var login: String {
        if case .signedIn(let login, _) = model.auth, !login.isEmpty { return login }
        return "RepoWatch"
    }

    // MARK: Inhalt

    @ViewBuilder
    private var content: some View {
        if model.syncState != nil {
            VStack(spacing: 0) {
                summary
                Divider()
                List(model.visibleRepositories) { repo in
                    RepoRowView(repo: repo)
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
            }
        } else if let message = model.lastError {
            ContentUnavailableView {
                Label("Laden fehlgeschlagen", systemImage: "exclamationmark.triangle")
            } description: {
                Text(message)
            } actions: {
                Button("Erneut versuchen") { model.refresh() }
            }
        } else {
            ContentUnavailableView {
                Label("Lade Repositories …", systemImage: "tray.and.arrow.down")
            }
        }
    }

    private var summary: some View {
        let repos = model.visibleRepositories
        return HStack(spacing: 16) {
            CountBadge("Repositories", systemImage: "books.vertical", count: repos.count)
            CountBadge("Offene Issues", systemImage: "smallcircle.filled.circle", count: repos.reduce(0) { $0 + $1.openIssueCount })
            CountBadge("Offene Pull Requests", systemImage: "arrow.triangle.pull", count: repos.reduce(0) { $0 + $1.openPullRequestCount })
            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    // MARK: Fuß

    private var footer: some View {
        HStack(spacing: 6) {
            if let message = model.lastError, model.syncState != nil {
                // Fehler bei vorhandenen Daten: alter Stand bleibt sichtbar, Hinweis unten.
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .help(retryHelp(message))
            }
            if let state = model.syncState, let lastSync = state.lastSyncAt {
                Text(model.lastError == nil ? "Aktualisiert" : "Stand von")
                RelativeTimeText(lastSync)
                if let rateLimit = state.rateLimit {
                    Text("·")
                    Text("API \(rateLimit.remaining.formatted()) / \(rateLimit.limit.formatted())")
                        .monospacedDigit()
                        .help("Verbleibendes GraphQL-Kontingent bis \(rateLimit.resetAt.formatted(date: .omitted, time: .shortened))")
                }
            }
            Spacer()
            Button("Beenden", action: onQuit)
                .buttonStyle(.borderless)
                .keyboardShortcut("q")
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    private func retryHelp(_ message: String) -> String {
        guard let retryAt = model.nextRetryAt else { return message }
        return "\(message)\nNächster Versuch \(retryAt.formatted(date: .omitted, time: .shortened))"
    }
}

private struct RepoRowView: View {
    let repo: RepoMeta

    var body: some View {
        Link(destination: repo.url) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(repo.name)
                        .font(.body.weight(.medium))
                    if repo.isPrivate {
                        Image(systemName: "lock.fill")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                            .accessibilityLabel("Privat")
                    }
                    Spacer()
                    if let pushedAt = repo.pushedAt {
                        RelativeTimeText(pushedAt)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                HStack(spacing: 12) {
                    Text(repo.owner)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                    CountBadge("Offene Issues", systemImage: "smallcircle.filled.circle", count: repo.openIssueCount)
                    CountBadge("Offene Pull Requests", systemImage: "arrow.triangle.pull", count: repo.openPullRequestCount)
                }
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .padding(.vertical, 2)
    }
}
