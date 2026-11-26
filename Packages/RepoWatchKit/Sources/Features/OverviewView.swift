import ActivityModule
import DesignSystem
import Domain
import ModuleUIKit
import SwiftUI

/// Übersicht: Favoriten oben, dann alle Repos (Konzept 3.2).
struct OverviewView: View {
    let model: AppModel
    let onSelect: (String) -> Void

    @State private var selection: String?

    private var context: ModuleUIContext { model.ui }

    private var filtered: [RepoSnapshot] {
        context.repositories.filter { context.matchesSearch($0.meta.nameWithOwner) }
    }

    private func sorted(_ repositories: [RepoSnapshot]) -> [RepoSnapshot] {
        switch model.settings.overviewSort {
        case .activity:
            let scores = Dictionary(uniqueKeysWithValues: repositories.map {
                ($0.id, $0.summaries[ActivityModule.id]?.counts["score"] ?? 0)
            })
            return repositories.sorted {
                (scores[$0.id] ?? 0, $0.meta.pushedAt ?? .distantPast) > (scores[$1.id] ?? 0, $1.meta.pushedAt ?? .distantPast)
            }
        case .name:
            return repositories.sorted { $0.meta.nameWithOwner.localizedCaseInsensitiveCompare($1.meta.nameWithOwner) == .orderedAscending }
        case .lastPush:
            return repositories.sorted { ($0.meta.pushedAt ?? .distantPast) > ($1.meta.pushedAt ?? .distantPast) }
        case .openItems:
            return repositories.sorted {
                $0.meta.openIssueCount + $0.meta.openPullRequestCount > $1.meta.openIssueCount + $1.meta.openPullRequestCount
            }
        }
    }

    var body: some View {
        let repositories = filtered
        let favorites = sorted(repositories.filter { model.settings.isFavorite($0.meta.nameWithOwner) })
        let others = sorted(repositories.filter { !model.settings.isFavorite($0.meta.nameWithOwner) })

        VStack(spacing: 0) {
            if !model.restrictedOrganizations.isEmpty {
                restrictionBanner
                Divider()
            }
            list(repositories: repositories, favorites: favorites, others: others)
        }
    }

    /// Hinweis, wenn Organisationen RepoWatch sperren; deren Repos fehlen sonst ohne erkennbaren Grund.
    private var restrictionBanner: some View {
        let names = model.restrictedOrganizations.filter { !$0.isEmpty }
        return HStack(alignment: .top, spacing: 8) {
            Image(systemName: "lock.trianglebadge.exclamationmark")
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text(names.isEmpty
                     ? String(localized: "Eine Organisation sperrt den Zugriff von RepoWatch.")
                     : String(localized: "Gesperrt durch: \(names.formatted(.list(type: .and)))"))
                    .font(.callout)
                Text("Deren Repos fehlen, bis die Organisation RepoWatch freigibt.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Link("Zugriff anfragen …", destination: model.accessRequestURL)
                    .font(.caption)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(Color.orange.opacity(0.1))
    }

    @ViewBuilder
    private func list(repositories: [RepoSnapshot], favorites: [RepoSnapshot], others: [RepoSnapshot]) -> some View {
        if repositories.isEmpty {
            EmptyStateView("Keine Repositories", systemImage: "books.vertical",
                           message: context.searchText.isEmpty ? "Prüfe die Filter in den Einstellungen." : "Nichts passt zur Suche.")
        } else {
            List(selection: $selection) {
                if !favorites.isEmpty {
                    Section {
                        rows(favorites)
                    } header: {
                        Label { SectionTitle(String(localized: "Favoriten"), count: favorites.count) } icon: {
                            Image(systemName: "star.fill").foregroundStyle(.yellow)
                        }
                    }
                }
                Section {
                    rows(others)
                } header: {
                    HStack {
                        SectionTitle(String(localized: "Alle Repositories"), count: others.count)
                        Spacer()
                        sortMenu
                    }
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .onKeyPress(.return) {
                guard let selection else { return .ignored }
                onSelect(selection)
                return .handled
            }
        }
    }

    @ViewBuilder
    private func rows(_ repositories: [RepoSnapshot]) -> some View {
        ForEach(repositories) { repository in
            RepositoryRow(repository: repository, model: model)
                .tag(repository.id)
                .contentShape(.rect)
                .onTapGesture { onSelect(repository.id) }
                .contextMenu { contextMenu(for: repository) }
        }
    }

    @ViewBuilder
    private func contextMenu(for repository: RepoSnapshot) -> some View {
        let name = repository.meta.nameWithOwner
        Button("Im Browser öffnen") { context.open(repository.meta.url) }
        Button("Link kopieren") { context.copy(repository.meta.url) }
        Divider()
        Button("Als gesehen markieren") { model.markSeen(repository.id) }
        Button(model.settings.isFavorite(name) ? "Aus Favoriten entfernen" : "Zu Favoriten") {
            model.toggleFavorite(name)
        }
    }

    private var sortMenu: some View {
        Menu {
            Picker("Sortieren", selection: Binding(
                get: { model.settings.overviewSort },
                set: { value in model.updateSettings { $0.overviewSort = value } }
            )) {
                Text("Aktivität").tag(AppSettings.OverviewSort.activity)
                Text("Name").tag(AppSettings.OverviewSort.name)
                Text("Letzter Push").tag(AppSettings.OverviewSort.lastPush)
                Text("Offene Einträge").tag(AppSettings.OverviewSort.openItems)
            }
            .pickerStyle(.inline)
        } label: {
            Label("Sortieren", systemImage: "arrow.up.arrow.down")
                .labelStyle(.iconOnly)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Sortieren")
        .accessibilityLabel("Sortieren")
    }
}

/// Eine Repo-Zeile: Name, Modul-Symbole und Zeit oben, Modul-Zusatzinfos unten (Konzept 3.2).
struct RepositoryRow: View {
    let repository: RepoSnapshot
    let model: AppModel

    var body: some View {
        let context = model.ui
        let modules = model.enabledModuleUIs
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                if model.hasNews(repository) { NewDot() }
                Text(repository.meta.name)
                    .font(.body.weight(.medium))
                    .lineLimit(1)
                if repository.meta.isPrivate {
                    Image(systemName: "lock.fill")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .accessibilityLabel("Privat")
                }
                if repository.lastDetailError != nil {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                        .help(repository.lastDetailError ?? "")
                }
                Spacer(minLength: 4)
                ForEach(modules.indices, id: \.self) { index in
                    modules[index].rowBadge(for: repository, context: context)
                }
                if let pushedAt = repository.meta.pushedAt {
                    RelativeTimeText(pushedAt)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(minWidth: 62, alignment: .trailing)
                }
            }
            HStack(spacing: 10) {
                Text(repository.meta.owner)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                ForEach(modules.indices, id: \.self) { index in
                    modules[index].rowAccessory(for: repository, context: context)
                }
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
        .accessibilityHint("Öffnet die Details")
    }
}
