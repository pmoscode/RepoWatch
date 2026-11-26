import DesignSystem
import Domain
import ModuleUIKit
import SwiftUI

/// Darstellung des Issues-Moduls (Konzept 3.2).
public struct IssuesUI: ModuleUI {
    public let moduleID = IssuesModule.id
    public let title = String(localized: "Issues")
    public let systemImage = "smallcircle.filled.circle"

    public init() {}

    /// Offene Issues ohne Bot-Issues, wenn so eingestellt (z. B. Renovates „Dependency Dashboard“).
    @MainActor
    static func count(_ payload: IssuesPayload, context: ModuleUIContext) -> Int {
        guard context.settings.issuesHideBotIssues else { return payload.totalCount }
        return max(0, payload.totalCount - payload.items.filter { $0.isFromBot(rules: context.settings.authorRules) }.count)
    }

    @MainActor
    static func visibleItems(_ payload: IssuesPayload, context: ModuleUIContext) -> [IssueSummary] {
        guard context.settings.issuesHideBotIssues else { return payload.items }
        return payload.items.filter { !$0.isFromBot(rules: context.settings.authorRules) }
    }

    public func rowAccessory(for repository: RepoSnapshot, context: ModuleUIContext) -> AnyView? {
        guard let payload = repository.payload(IssuesPayload.self, for: moduleID) else { return nil }
        return AnyView(CountBadge("Offene Issues", systemImage: systemImage, count: Self.count(payload, context: context)))
    }

    public func detailSection(for repository: RepoSnapshot, context: ModuleUIContext) -> AnyView? {
        guard let payload = repository.payload(IssuesPayload.self, for: moduleID) else { return nil }
        return AnyView(IssueDetailSection(repository: repository, payload: payload, context: context))
    }

    public func tab(context: ModuleUIContext) -> ModuleTab? {
        let total = context.repositories.compactMap { $0.payload(IssuesPayload.self, for: moduleID) }
            .reduce(0) { $0 + Self.count($1, context: context) }
        return ModuleTab(id: moduleID, title: title, systemImage: systemImage, badge: total, content: IssuesTabView(context: context))
    }

    public func hasNews(in repository: RepoSnapshot, since date: Date) -> Bool {
        // Bot-Issues wie das „Dependency Dashboard“ ändern sich ständig und zählen nicht als neu.
        repository.payload(IssuesPayload.self, for: moduleID)?.items
            .contains { $0.updatedAt > date && !$0.isFromBot(rules: .default) } ?? false
    }
}

// MARK: - Zeile

struct IssueRow: View {
    let issue: IssueSummary
    let repositoryName: String?
    let isNew: Bool
    let context: ModuleUIContext

    var body: some View {
        Button {
            context.open(issue.url)
        } label: {
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    if isNew { NewDot() }
                    Text(issue.title)
                        .lineLimit(2)
                    Spacer(minLength: 4)
                    RelativeTimeText(issue.updatedAt)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                HStack(spacing: 6) {
                    Text([repositoryName, "#\(issue.number)"].compactMap { $0 }.joined(separator: " "))
                        .foregroundStyle(.secondary)
                    if let author = issue.author {
                        Text("· \(author)").foregroundStyle(.tertiary)
                    }
                    if issue.commentCount > 0 {
                        Label("\(issue.commentCount)", systemImage: "bubble.left")
                            .foregroundStyle(.tertiary)
                    }
                    ForEach(issue.labels, id: \.self) { label in
                        LabelChip(name: label.name, hexColor: label.color)
                    }
                }
                .font(.caption)
                .lineLimit(1)
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button("Im Browser öffnen") { context.open(issue.url) }
            Button("Link kopieren") { context.copy(issue.url) }
        }
    }
}

// MARK: - Reiter

struct IssuesTabView: View {
    let context: ModuleUIContext
    @State private var repositoryFilter: String?
    @State private var labelFilter: String?

    private struct Entry: Identifiable {
        let issue: IssueSummary
        let repository: RepoSnapshot
        var id: String { "\(repository.id)#\(issue.number)" }
    }

    private var entries: [Entry] {
        context.repositories
            .flatMap { repository in
                repository.payload(IssuesPayload.self, for: IssuesModule.id)
                    .map { IssuesUI.visibleItems($0, context: context) }?
                    .map { Entry(issue: $0, repository: repository) } ?? []
            }
            .filter { repositoryFilter == nil || $0.repository.id == repositoryFilter }
            .filter { labelFilter == nil || $0.issue.labels.contains { $0.name == labelFilter } }
            .filter { context.matchesSearch($0.issue.title, $0.repository.meta.nameWithOwner, $0.issue.author) }
            .sorted { $0.issue.updatedAt > $1.issue.updatedAt }
    }

    private var repositoriesWithIssues: [RepoSnapshot] {
        context.repositories.filter { ($0.payload(IssuesPayload.self, for: IssuesModule.id)?.totalCount ?? 0) > 0 }
            .sorted { $0.meta.nameWithOwner.localizedCaseInsensitiveCompare($1.meta.nameWithOwner) == .orderedAscending }
    }

    private var labels: [String] {
        Set(context.repositories.flatMap { $0.payload(IssuesPayload.self, for: IssuesModule.id)?.items.flatMap { $0.labels.map(\.name) } ?? [] })
            .sorted()
    }

    var body: some View {
        let entries = entries
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Menu {
                    Button("Alle Repositories") { repositoryFilter = nil }
                    Divider()
                    ForEach(repositoriesWithIssues) { repository in
                        Button(repository.meta.nameWithOwner) { repositoryFilter = repository.id }
                    }
                } label: {
                    Label(repositoryFilter.flatMap { context.repository(id: $0)?.meta.nameWithOwner } ?? String(localized: "Alle Repositories"),
                          systemImage: "line.3.horizontal.decrease")
                }
                Menu {
                    Button("Alle Labels") { labelFilter = nil }
                    Divider()
                    ForEach(labels, id: \.self) { label in
                        Button(label) { labelFilter = label }
                    }
                } label: {
                    Label(labelFilter ?? String(localized: "Alle Labels"), systemImage: "tag")
                }
                .disabled(labels.isEmpty)
                Spacer()
                Toggle("Ohne Bots", isOn: Binding(
                    get: { context.settings.issuesHideBotIssues },
                    set: { value in context.updateSettings { $0.issuesHideBotIssues = value } }
                ))
                .toggleStyle(.checkbox)
                .help("Issues von Bots ausblenden, z. B. Renovates „Dependency Dashboard“")
            }
            .menuStyle(.borderlessButton)
            .fixedSize(horizontal: false, vertical: true)
            .font(.caption)
            .padding(.horizontal, 14)
            .padding(.vertical, 6)
            Divider()

            if entries.isEmpty {
                EmptyStateView("Keine offenen Issues", systemImage: "checkmark.circle",
                               message: context.searchText.isEmpty ? nil : "Nichts passt zur Suche.")
            } else {
                List(entries) { entry in
                    IssueRow(
                        issue: entry.issue,
                        repositoryName: entry.repository.meta.nameWithOwner,
                        isNew: context.isNew(entry.issue.updatedAt, repositoryID: entry.repository.id),
                        context: context
                    )
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
            }
        }
    }
}

// MARK: - Detail

struct IssueDetailSection: View {
    let repository: RepoSnapshot
    let payload: IssuesPayload
    let context: ModuleUIContext

    @State private var extraItems: [IssueSummary] = []
    @State private var cursor: String?
    @State private var hasMore: Bool?
    @State private var isLoading = false
    @State private var loadError: String?

    private var items: [IssueSummary] {
        let known = Set(payload.items.map(\.number))
        let all = payload.items + extraItems.filter { !known.contains($0.number) }
        guard context.settings.issuesHideBotIssues else { return all }
        return all.filter { !$0.isFromBot(rules: context.settings.authorRules) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if items.isEmpty {
                Text(payload.totalCount == 0 ? "Keine offenen Issues" : "Nur Issues von Bots (ausgeblendet)")
                    .foregroundStyle(.secondary).font(.callout)
            }
            ForEach(items) { issue in
                IssueRow(issue: issue, repositoryName: nil,
                         isNew: context.isNew(issue.updatedAt, repositoryID: repository.id), context: context)
                Divider()
            }
            if hasMore ?? payload.hasMore {
                HStack {
                    Button {
                        Task { await loadMore() }
                    } label: {
                        Text("Weitere laden (\(payload.totalCount - items.count) offen)")
                    }
                    .buttonStyle(.link)
                    .disabled(isLoading || context.services == nil)
                    if isLoading { ProgressView().controlSize(.small) }
                }
                .font(.caption)
            }
            if let loadError {
                Text(loadError).font(.caption).foregroundStyle(.orange)
            }
        }
    }

    private func loadMore() async {
        guard let services = context.services else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            let page = try await IssuesModule.fetchPage(
                client: services.graphQL, repositoryID: repository.id, after: cursor ?? payload.endCursor
            )
            extraItems += page.items
            cursor = page.endCursor
            hasMore = page.hasMore
            loadError = nil
        } catch {
            loadError = error.localizedDescription
        }
    }
}
