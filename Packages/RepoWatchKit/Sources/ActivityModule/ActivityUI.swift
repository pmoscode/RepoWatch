import DesignSystem
import Domain
import GitHubAPI
import ModuleUIKit
import SwiftUI

/// Darstellung des Aktivitäts-Moduls (Konzept 3.2 und 7).
public struct ActivityUI: ModuleUI {
    public let moduleID = ActivityModule.id
    public let title = String(localized: "Aktivität")
    public let systemImage = "waveform.path.ecg"
    /// So viele Repos (die aktivsten) fließen in den Feed des Reiters ein.
    public static let feedRepositoryLimit = 15

    public init() {}

    /// Stufen aller Repos relativ zueinander (Konzept 7).
    @MainActor
    public static func levels(in context: ModuleUIContext) -> [String: ActivityLevel] {
        context.memo("activity.levels") {
            ActivityRanking.levels(for: Dictionary(uniqueKeysWithValues: context.repositories.map {
                ($0.id, $0.payload(ActivityPayload.self, for: ActivityModule.id)?.score ?? 0)
            }))
        }
    }

    public func rowBadge(for repository: RepoSnapshot, context: ModuleUIContext) -> AnyView? {
        guard repository.payload(ActivityPayload.self, for: moduleID) != nil else { return nil }
        let level = Self.levels(in: context)[repository.id] ?? .dormant
        return AnyView(ActivityIndicator(level: level.rawValue))
    }

    public func rowAccessory(for repository: RepoSnapshot, context: ModuleUIContext) -> AnyView? {
        guard let payload = repository.payload(ActivityPayload.self, for: moduleID), payload.commits7d > 0 else { return nil }
        return AnyView(
            Text("\(payload.commits7d) Commits/7T")
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()
        )
    }

    public func detailSection(for repository: RepoSnapshot, context: ModuleUIContext) -> AnyView? {
        guard let payload = repository.payload(ActivityPayload.self, for: moduleID) else { return nil }
        return AnyView(ActivityDetailSection(repository: repository, payload: payload, context: context))
    }

    public func tab(context: ModuleUIContext) -> ModuleTab? {
        ModuleTab(id: moduleID, title: title, systemImage: systemImage, badge: nil, content: ActivityFeedView(context: context))
    }
}

// MARK: - Ereignis-Zeile

struct EventRow: View {
    let event: ActivityEvent
    let repositoryName: String?
    let context: ModuleUIContext

    private var symbol: String {
        switch event.kind {
        case .push: "arrow.up.circle"
        case .pullRequestOpened: "arrow.triangle.pull"
        case .pullRequestMerged: "arrow.triangle.merge"
        case .pullRequestClosed: "xmark.circle"
        case .issueOpened: "smallcircle.filled.circle"
        case .issueClosed: "checkmark.circle"
        case .issueReopened: "arrow.uturn.backward.circle"
        case .comment: "bubble.left"
        case .review: "eye"
        case .release: "shippingbox.circle"
        case .branchOrTagCreated: "plus.circle"
        case .branchOrTagDeleted: "minus.circle"
        case .star: "star"
        case .fork: "tuningfork"
        case .other: "circle.dotted"
        }
    }

    private var verb: String {
        switch event.kind {
        case .push: String(localized: "hat gepusht")
        case .pullRequestOpened: String(localized: "hat einen PR geöffnet")
        case .pullRequestMerged: String(localized: "hat einen PR gemergt")
        case .pullRequestClosed: String(localized: "hat einen PR geschlossen")
        case .issueOpened: String(localized: "hat ein Issue geöffnet")
        case .issueClosed: String(localized: "hat ein Issue geschlossen")
        case .issueReopened: String(localized: "hat ein Issue wieder geöffnet")
        case .comment: String(localized: "hat kommentiert")
        case .review: String(localized: "hat reviewt")
        case .release: String(localized: "hat ein Release veröffentlicht")
        case .branchOrTagCreated: String(localized: "hat angelegt")
        case .branchOrTagDeleted: String(localized: "hat gelöscht")
        case .star: String(localized: "hat einen Stern vergeben")
        case .fork: String(localized: "hat geforkt")
        case .other: String(localized: "Ereignis")
        }
    }

    var body: some View {
        Button {
            if let url = event.url { context.open(url) }
        } label: {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: symbol)
                    .foregroundStyle(event.kind == .pullRequestMerged ? Color.purple : .secondary)
                    .frame(width: 16)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 4) {
                        Text(event.actor).fontWeight(.medium)
                        Text(verb).foregroundStyle(.secondary)
                        Spacer(minLength: 4)
                        RelativeTimeText(event.createdAt).font(.caption).foregroundStyle(.secondary)
                    }
                    .lineLimit(1)
                    let line = [repositoryName, event.detail].compactMap { $0 }.joined(separator: " · ")
                    if !line.isEmpty {
                        Text(line).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Reiter: Feed

/// Chronologischer Feed der aktivsten Repos (Konzept 3.2). Lädt beim Öffnen; dank ETag
/// sind unveränderte Abfragen kostenlos. Die Events-API hinkt bis zu einigen Stunden hinterher.
struct ActivityFeedView: View {
    let context: ModuleUIContext
    @State private var events: [(repository: String, event: ActivityEvent)] = []
    @State private var isLoading = false
    @State private var failures = 0

    private var feedRepositories: [RepoSnapshot] {
        context.repositories
            .filter { ($0.payload(ActivityPayload.self, for: ActivityModule.id)?.score ?? 0) > 0 }
            .sorted {
                ($0.payload(ActivityPayload.self, for: ActivityModule.id)?.score ?? 0)
                    > ($1.payload(ActivityPayload.self, for: ActivityModule.id)?.score ?? 0)
            }
            .prefix(ActivityUI.feedRepositoryLimit)
            .map { $0 }
    }

    var body: some View {
        let visible = events.filter { context.matchesSearch($0.repository, $0.event.actor, $0.event.detail) }
        Group {
            if visible.isEmpty && isLoading {
                ProgressView("Lade Ereignisse …").controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if visible.isEmpty {
                EmptyStateView("Keine Ereignisse", systemImage: "waveform.path.ecg",
                               message: "In den letzten Tagen war es ruhig.")
            } else {
                List {
                    Section {
                        ForEach(visible, id: \.event.id) { item in
                            EventRow(event: item.event, repositoryName: item.repository, context: context)
                        }
                    } footer: {
                        Text("Aus den \(feedRepositories.count) aktivsten Repos. GitHub meldet Ereignisse mit bis zu einigen Stunden Verzögerung.")
                            .font(.caption2).foregroundStyle(.tertiary)
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
            }
        }
        .task(id: feedRepositories.map(\.id)) { await load() }
    }

    private func load() async {
        guard let services = context.services else { return }
        isLoading = true
        defer { isLoading = false }
        let repositories = feedRepositories.map(\.meta.nameWithOwner)
        var collected: [(String, ActivityEvent)] = []
        var failed = 0
        await withTaskGroup(of: (String, [ActivityEvent]?).self) { group in
            for name in repositories {
                group.addTask {
                    (name, try? await ActivityModule.fetchEvents(rest: services.rest, nameWithOwner: name, limit: 15))
                }
            }
            for await (name, result) in group {
                if let result { collected += result.map { (name, $0) } } else { failed += 1 }
            }
        }
        events = collected
            .filter { $0.1.kind != .other }
            .sorted { $0.1.createdAt > $1.1.createdAt }
            .prefix(100)
            .map { (repository: $0.0, event: $0.1) }
        failures = failed
    }
}

// MARK: - Detail

struct ActivityDetailSection: View {
    let repository: RepoSnapshot
    let payload: ActivityPayload
    let context: ModuleUIContext

    @State private var weekly: [Int]?
    @State private var weeklyPending = false
    @State private var events: [ActivityEvent] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 4) {
                GridRow {
                    stat("Commits 7 Tage", payload.commits7d)
                    stat("Commits 30 Tage", payload.commits30d)
                }
                GridRow {
                    stat("Issues neu / zu", "\(payload.issuesOpened7d) / \(payload.issuesClosed7d)")
                    stat("PRs neu / gemergt", "\(payload.prsOpened7d) / \(payload.prsMerged7d)")
                }
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Commits pro Woche (52 Wochen)").font(.caption).foregroundStyle(.secondary)
                if let weekly, weekly.isEmpty {
                    Text("Keine Daten").font(.caption).foregroundStyle(.tertiary)
                } else if let weekly {
                    Sparkline(values: weekly).frame(height: 36)
                } else if weeklyPending {
                    Text("GitHub berechnet die Statistik noch – gleich noch einmal öffnen.")
                        .font(.caption).foregroundStyle(.tertiary)
                } else {
                    ProgressView().controlSize(.small)
                }
            }

            if !events.isEmpty {
                Text("Letzte Ereignisse").font(.caption).foregroundStyle(.secondary)
                ForEach(events.prefix(10)) { event in
                    EventRow(event: event, repositoryName: nil, context: context)
                }
            }
        }
        .task(id: repository.id) { await load() }
    }

    private func stat(_ title: LocalizedStringKey, _ value: some CustomStringConvertible) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title).font(.caption2).foregroundStyle(.secondary)
            Text(value.description).font(.callout.monospacedDigit())
        }
    }

    private func load() async {
        guard let services = context.services else {
            weekly = []
            return
        }
        let name = repository.meta.nameWithOwner
        do {
            weekly = try await ActivityModule.fetchWeeklyCommits(rest: services.rest, nameWithOwner: name)
        } catch GitHubAPIError.pending {
            weeklyPending = true
        } catch {
            weekly = []
        }
        events = (try? await ActivityModule.fetchEvents(rest: services.rest, nameWithOwner: name, limit: 15))?
            .filter { $0.kind != .other } ?? []
    }
}
