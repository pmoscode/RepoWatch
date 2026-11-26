import DesignSystem
import Domain
import ModuleUIKit
import SwiftUI

/// Eigener Reiter für Renovate-PRs: Org → Repo → PRs, mit CI-Status und Links auf die
/// gefilterte PR-Liste bei GitHub. Nutzt die Daten des PR-Moduls; fragt nichts zusätzlich ab.
public struct RenovateUI: ModuleUI {
    public let moduleID = ModuleID("renovate")
    public let title = "Renovate"
    public let systemImage = "shippingbox"

    public init() {}

    public func tab(context: ModuleUIContext) -> ModuleTab? {
        let groups = RenovateOverview.groups(from: context.repositories, viewerLogin: context.viewerLogin)
        let failing = groups.reduce(0) { $0 + $1.counts.failing }
        let total = groups.reduce(0) { $0 + $1.counts.total }
        // Rote Checks zuerst: Die Zahl zeigt sie rot; sonst die Gesamtzahl.
        return ModuleTab(
            id: moduleID, title: title, systemImage: systemImage,
            badge: failing > 0 ? failing : total, isAlert: failing > 0,
            content: RenovateTabView(context: context)
        )
    }
}

// MARK: - Bausteine

/// „✗ 2  ✓ 17  ⏳ 1“
struct RenovateCounts: View {
    let counts: RenovateOverview.Counts

    var body: some View {
        HStack(spacing: 8) {
            if counts.failing > 0 { count(.failure, counts.failing) }
            if counts.passing > 0 { count(.success, counts.passing) }
            if counts.pending > 0 { count(.pending, counts.pending) }
            if counts.unchecked > 0 { count(.neutral, counts.unchecked) }
        }
        .font(.caption)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("\(counts.failing) rot, \(counts.passing) grün, \(counts.pending) ausstehend, \(counts.unchecked) ohne Checks"))
    }

    private func count(_ tone: StatusTone, _ value: Int) -> some View {
        HStack(spacing: 2) {
            StatusIcon(tone)
            Text(value, format: .number).monospacedDigit()
        }
    }
}

/// Knopf „auf GitHub öffnen“ für die gefilterte PR-Liste.
struct PullRequestsLink: View {
    let url: URL
    let help: LocalizedStringKey
    let context: ModuleUIContext

    var body: some View {
        Button {
            context.open(url)
        } label: {
            Image(systemName: "arrow.up.forward.square")
        }
        .buttonStyle(.borderless)
        .help(help)
        .accessibilityLabel(Text(help))
        .contextMenu {
            Button("Link kopieren") { context.copy(url) }
        }
    }
}

struct RenovatePullRequestRow: View {
    let pr: PullRequestSummary
    let context: ModuleUIContext

    var body: some View {
        Button {
            context.open(pr.url)
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                StatusIcon(StatusTone(pr.ci))
                Text(RenovateOverview.shortTitle(pr.title))
                    .lineLimit(1)
                    .help(pr.title)
                Spacer(minLength: 4)
                Text("#\(pr.number)").foregroundStyle(.tertiary).monospacedDigit()
                RelativeTimeText(pr.updatedAt).foregroundStyle(.secondary)
            }
            .font(.callout)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .padding(.leading, 34)
        .contextMenu {
            Button("Im Browser öffnen") { context.open(pr.url) }
            Button("Link kopieren") { context.copy(pr.url) }
        }
    }
}

// MARK: - Reiter

struct RenovateTabView: View {
    let context: ModuleUIContext
    @State private var expandedOwners: Set<String>?
    @State private var expandedRepositories: Set<String>?

    var body: some View {
        let groups = RenovateOverview.groups(from: context.repositories, viewerLogin: context.viewerLogin) { repository, pr in
            context.matchesSearch(repository.nameWithOwner, pr.title, pr.branch)
        }
        let searching = !context.searchText.isEmpty
        // Beim ersten Anzeigen: Orgs und Repos mit roten Checks aufgeklappt.
        let expanded = expandedOwners ?? Set(groups.filter { $0.counts.failing > 0 }.map(\.owner))
        let expandedRepos = expandedRepositories
            ?? Set(groups.flatMap(\.repositories).filter { $0.counts.failing > 0 }.map(\.id))

        if groups.isEmpty {
            EmptyStateView("Keine Renovate-PRs", systemImage: "shippingbox",
                           message: searching ? "Nichts passt zur Suche." : "Alle Abhängigkeiten sind aktuell.")
        } else {
            List {
                ForEach(groups) { group in
                    let ownerExpanded = searching || expanded.contains(group.owner)
                    Section {
                        if ownerExpanded {
                            ForEach(group.repositories) { repository in
                                repositoryRow(repository, expanded: searching || expandedRepos.contains(repository.id), current: expandedRepos)
                                if searching || expandedRepos.contains(repository.id) {
                                    // Nummern sind nur je Repo eindeutig; die URL ist es überall.
                                    ForEach(repository.pullRequests, id: \.url) { pr in
                                        RenovatePullRequestRow(pr: pr, context: context)
                                    }
                                }
                            }
                        }
                    } header: {
                        ownerHeader(group, expanded: ownerExpanded, current: expanded)
                    }
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
        }
    }

    private func ownerHeader(_ group: RenovateOverview.OwnerGroup, expanded: Bool, current: Set<String>) -> some View {
        HStack(spacing: 6) {
            Button {
                var next = current
                if next.contains(group.owner) { next.remove(group.owner) } else { next.insert(group.owner) }
                expandedOwners = next
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: expanded ? "chevron.down" : "chevron.right")
                        .font(.caption2)
                        .frame(width: 10)
                    Text(group.owner)
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Text("\(group.counts.total == 1 ? "1 PR" : "\(group.counts.total) PRs") · \(group.repositories.count == 1 ? "1 Repo" : "\(group.repositories.count) Repos")")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                    Spacer(minLength: 4)
                }
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            RenovateCounts(counts: group.counts)
            PullRequestsLink(url: group.pullRequestsURL, help: "Alle Renovate-PRs von \(group.owner) auf GitHub", context: context)
        }
    }

    private func repositoryRow(_ group: RenovateOverview.RepositoryGroup, expanded: Bool, current: Set<String>) -> some View {
        HStack(spacing: 6) {
            Button {
                var next = current
                if next.contains(group.id) { next.remove(group.id) } else { next.insert(group.id) }
                expandedRepositories = next
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: expanded ? "chevron.down" : "chevron.right")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .frame(width: 10)
                    Text(group.repository.name)
                        .lineLimit(1)
                    Text(group.isIncomplete ? "\(group.counts.total)+" : "\(group.counts.total)")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .monospacedDigit()
                        .help(group.isIncomplete ? Text("Mehr offene PRs als geladen") : Text("Offene Renovate-PRs"))
                    Spacer(minLength: 4)
                }
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            RenovateCounts(counts: group.counts)
            PullRequestsLink(url: group.pullRequestsURL, help: "Renovate-PRs von \(group.repository.name) auf GitHub", context: context)
        }
        .padding(.leading, 14)
        .contextMenu {
            Button("PR-Liste im Browser öffnen") { context.open(group.pullRequestsURL) }
            Button("Link zur PR-Liste kopieren") { context.copy(group.pullRequestsURL) }
            Button("Repo-Details") { context.showRepository(group.id) }
        }
    }
}
