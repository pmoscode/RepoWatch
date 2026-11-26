import DesignSystem
import Domain
import SwiftUI

/// Inhalt des Menüleisten-Panels. Phase 0: Bestand als einfache Liste.
public struct PanelRootView: View {
    private let model: AppModel
    private let onQuit: () -> Void

    public init(model: AppModel, onQuit: @escaping () -> Void) {
        self.model = model
        self.onQuit = onQuit
    }

    public var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            footer
        }
        .frame(width: 400, height: 560)
    }

    // MARK: Kopf

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "person.crop.circle")
                .foregroundStyle(.secondary)
            Text(model.inventory?.viewerLogin ?? "RepoWatch")
                .font(.headline)
            Spacer()
            if model.state == .loading {
                ProgressView()
                    .controlSize(.small)
            }
            Button {
                model.refresh()
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.borderless)
            .keyboardShortcut("r")
            .help("Aktualisieren (⌘R)")
            .disabled(model.state == .loading)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    // MARK: Inhalt

    @ViewBuilder
    private var content: some View {
        if model.inventory != nil {
            VStack(spacing: 0) {
                summary
                Divider()
                List(model.visibleRepositories) { repo in
                    RepoRowView(repo: repo)
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
            }
        } else {
            switch model.state {
            case .failed(let message):
                ContentUnavailableView {
                    Label("Laden fehlgeschlagen", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(message)
                } actions: {
                    Button("Erneut versuchen") { model.refresh() }
                }
            case .idle, .loading, .loaded:
                ContentUnavailableView {
                    Label("Lade Repositories …", systemImage: "tray.and.arrow.down")
                }
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
            if case .failed(let message) = model.state, model.inventory != nil {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .help(message)
            }
            if let inventory = model.inventory {
                Text("Aktualisiert")
                RelativeTimeText(inventory.fetchedAt)
                if let rateLimit = inventory.rateLimit {
                    Text("·")
                    Text("API \(rateLimit.remaining.formatted()) / \(rateLimit.limit.formatted())")
                        .monospacedDigit()
                        .help("Kosten dieses Durchlaufs: \(inventory.totalCost) Punkt(e) in \(inventory.pageCount) Seite(n)")
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
