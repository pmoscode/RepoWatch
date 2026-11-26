import DesignSystem
import Domain
import ModuleUIKit
import SwiftUI

/// Darstellung des PR-Moduls (Konzept 3.2): gruppiert nach Autor-Art, Bots eingeklappt.
public struct PullRequestsUI: ModuleUI {
    public let moduleID = PullRequestsModule.id
    public let title = String(localized: "PRs")
    public let systemImage = "arrow.triangle.pull"

    public init() {}

    public func rowAccessory(for repository: RepoSnapshot, context: ModuleUIContext) -> AnyView? {
        guard let payload = repository.payload(PullRequestsPayload.self, for: moduleID) else { return nil }
        return AnyView(PullRequestCounts(payload: payload))
    }

    public func detailSection(for repository: RepoSnapshot, context: ModuleUIContext) -> AnyView? {
        guard let payload = repository.payload(PullRequestsPayload.self, for: moduleID) else { return nil }
        return AnyView(
            VStack(alignment: .leading, spacing: 8) {
                if payload.items.isEmpty {
                    Text("Keine offenen Pull Requests").foregroundStyle(.secondary).font(.callout)
                }
                ForEach(payload.items.sorted(by: PullRequestSummary.attentionFirst)) { pr in
                    PullRequestRow(pr: pr, repositoryName: nil,
                                   isNew: context.isNew(pr.updatedAt, repositoryID: repository.id), context: context)
                    Divider()
                }
                if payload.hasMore {
                    Link("Alle \(payload.totalCount) auf GitHub", destination: repository.meta.url.appending(path: "pulls"))
                        .font(.caption)
                }
            }
        )
    }

    public func tab(context: ModuleUIContext) -> ModuleTab? {
        let payloads = context.repositories.compactMap { $0.payload(PullRequestsPayload.self, for: moduleID) }
        let people = payloads.reduce(0) { $0 + $1.count(.human) + $1.count(.me) }
        let failing = payloads.contains { $0.items.contains { $0.authorKind.isPerson && $0.ci == .failure } }
        // Die Zahl am Reiter: PRs von Menschen; dort wartet meist eine Review (Konzept 3.2).
        return ModuleTab(id: moduleID, title: title, systemImage: systemImage, badge: people, isAlert: failing,
                         content: PullRequestsTabView(context: context))
    }

    public func hasNews(in repository: RepoSnapshot, since date: Date) -> Bool {
        repository.payload(PullRequestsPayload.self, for: moduleID)?.items.contains { $0.updatedAt > date } ?? false
    }
}

extension PullRequestSummary {
    /// Menschen zuerst, darin rote Checks zuerst, dann nach letzter Änderung.
    static func attentionFirst(_ lhs: PullRequestSummary, _ rhs: PullRequestSummary) -> Bool {
        if lhs.authorKind.isPerson != rhs.authorKind.isPerson { return lhs.authorKind.isPerson }
        if (lhs.ci == .failure) != (rhs.ci == .failure) { return lhs.ci == .failure }
        return lhs.updatedAt > rhs.updatedAt
    }
}

// MARK: - Bausteine

/// „⇄ 3 (👤 1 · 🤖 2)“ in der Repo-Zeile.
struct PullRequestCounts: View {
    let payload: PullRequestsPayload

    var body: some View {
        let people = payload.count(.human) + payload.count(.me)
        let bots = payload.totalCount - people
        HStack(spacing: 4) {
            CountBadge("Offene Pull Requests", systemImage: "arrow.triangle.pull", count: payload.totalCount)
            if payload.totalCount > 0 {
                HStack(spacing: 3) {
                    if people > 0 {
                        Image(systemName: "person.fill")
                        Text(people, format: .number)
                    }
                    if bots > 0 {
                        Image(systemName: "shippingbox")
                        Text(bots, format: .number)
                    }
                }
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .help(Text("\(people) von Menschen, \(bots) von Bots"))
            }
            if payload.items.contains(where: { $0.authorKind.isPerson && $0.ci == .failure }) {
                StatusIcon(.failure).font(.caption2)
            }
        }
    }
}

struct PullRequestRow: View {
    let pr: PullRequestSummary
    let repositoryName: String?
    let isNew: Bool
    let context: ModuleUIContext

    var body: some View {
        Button {
            context.open(pr.url)
        } label: {
            HStack(alignment: .top, spacing: 8) {
                StatusIcon(StatusTone(pr.ci))
                    .font(.callout)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        if isNew { NewDot() }
                        Text(pr.title).lineLimit(2)
                        if pr.isDraft { TagText("Entwurf") }
                        Spacer(minLength: 4)
                        RelativeTimeText(pr.updatedAt)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    HStack(spacing: 6) {
                        AuthorKindIcon(pr.authorKind)
                        Text([repositoryName, "#\(pr.number)"].compactMap { $0 }.joined(separator: " "))
                            .foregroundStyle(.secondary)
                        if let login = pr.authorLogin, pr.authorKind.isPerson {
                            Text("· \(login)").foregroundStyle(.tertiary)
                        }
                    }
                    .font(.caption)
                    .lineLimit(1)
                }
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button("Im Browser öffnen") { context.open(pr.url) }
            Button("Link kopieren") { context.copy(pr.url) }
        }
    }
}

// MARK: - Reiter

struct PullRequestsTabView: View {
    let context: ModuleUIContext
    @State private var expandedBotGroups: Set<AuthorKind.Category> = []

    private struct Entry: Identifiable {
        let pr: PullRequestSummary
        let repository: RepoSnapshot
        var id: String { "\(repository.id)#\(pr.number)" }
    }

    private var grouped: [(category: AuthorKind.Category, entries: [Entry])] {
        let all = context.repositories.flatMap { repository in
            (repository.payload(PullRequestsPayload.self, for: PullRequestsModule.id)?.items ?? [])
                .map { Entry(pr: $0, repository: repository) }
        }
        .filter { context.matchesSearch($0.pr.title, $0.repository.meta.nameWithOwner, $0.pr.authorLogin, $0.pr.branch) }

        // Reihenfolge nach Konzept 3.2: Menschen, ich, Renovate, Dependabot, andere Bots.
        let order: [AuthorKind.Category] = [.human, .me, .renovate, .dependabot, .otherBot]
        return order.compactMap { category in
            let entries = all.filter { $0.pr.authorKind.category == category }
                .sorted { PullRequestSummary.attentionFirst($0.pr, $1.pr) }
            return entries.isEmpty ? nil : (category, entries)
        }
    }

    var body: some View {
        let groups = grouped
        if groups.isEmpty {
            EmptyStateView("Keine offenen Pull Requests", systemImage: "checkmark.circle",
                           message: context.searchText.isEmpty ? nil : "Nichts passt zur Suche.")
        } else {
            List {
                ForEach(groups, id: \.category) { group in
                    let isBot = !(group.category == .human || group.category == .me)
                    Section {
                        if !isBot || expandedBotGroups.contains(group.category) || !context.searchText.isEmpty {
                            ForEach(group.entries) { entry in
                                PullRequestRow(pr: entry.pr, repositoryName: entry.repository.meta.nameWithOwner,
                                               isNew: context.isNew(entry.pr.updatedAt, repositoryID: entry.repository.id),
                                               context: context)
                            }
                        }
                    } header: {
                        header(for: group.category, entries: group.entries, collapsible: isBot)
                    }
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
        }
    }

    @ViewBuilder
    private func header(for category: AuthorKind.Category, entries: [Entry], collapsible: Bool) -> some View {
        let repositories = Set(entries.map(\.repository.id)).count
        let failing = entries.filter { $0.pr.ci == .failure }.count
        Button {
            guard collapsible else { return }
            if expandedBotGroups.contains(category) { expandedBotGroups.remove(category) } else { expandedBotGroups.insert(category) }
        } label: {
            HStack(spacing: 6) {
                if collapsible {
                    Image(systemName: expandedBotGroups.contains(category) ? "chevron.down" : "chevron.right")
                        .font(.caption2)
                        .frame(width: 10)
                }
                Image(systemName: AuthorKindIcon.systemImage(for: category))
                SectionTitle(AuthorKindIcon.title(for: category), count: entries.count)
                if collapsible {
                    Text("in \(repositories) Repos").font(.caption).foregroundStyle(.tertiary)
                }
                Spacer()
                if failing > 0 {
                    HStack(spacing: 2) {
                        StatusIcon(.failure)
                        Text(failing, format: .number).monospacedDigit()
                    }
                    .font(.caption)
                    .help(Text("\(failing) mit roten Checks"))
                }
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
    }
}
