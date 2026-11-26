import DesignSystem
import Domain
import ModuleUIKit
import SwiftUI

extension RunOutcome {
    var tone: StatusTone {
        switch self {
        case .success: .success
        case .failure: .failure
        case .running: .running
        case .cancelled: .cancelled
        case .skipped: .neutral
        case .actionRequired: .pending
        }
    }
}

/// Darstellung des Actions-Moduls (Konzept 3.2 und 8).
public struct ActionsUI: ModuleUI {
    public let moduleID = ActionsModule.id
    public let title = String(localized: "Actions")
    public let systemImage = "gearshape.2"
    private let module: ActionsModule

    public init(module: ActionsModule) {
        self.module = module
    }

    /// Status des Standard-Branches für die Repo-Zeile: ✓ / ✗ / läuft / – / kein CI.
    public func rowBadge(for repository: RepoSnapshot, context: ModuleUIContext) -> AnyView? {
        guard let payload = repository.payload(ActionsPayload.self, for: moduleID) else { return nil }
        guard payload.hasWorkflows || payload.headStatus != nil else {
            return AnyView(Text("kein CI").font(.caption2).foregroundStyle(.tertiary))
        }
        let running = payload.defaultBranchStates.contains(where: \.isRunning)
        let tone: StatusTone = running ? .running : StatusTone(payload.headStatus)
        return AnyView(
            HStack(spacing: 2) {
                StatusIcon(tone)
                if let branch = payload.defaultBranch {
                    Text(branch).font(.caption2).foregroundStyle(.secondary)
                }
            }
        )
    }

    /// „✗ seit 2 Tg.“, wenn der Standard-Branch rot ist.
    public func rowAccessory(for repository: RepoSnapshot, context: ModuleUIContext) -> AnyView? {
        guard let payload = repository.payload(ActionsPayload.self, for: moduleID),
              let failing = payload.defaultBranchStates.first(where: \.isFailing),
              let since = failing.failingSince else { return nil }
        return AnyView(
            HStack(spacing: 2) {
                Text("rot seit")
                RelativeTimeText(since)
            }
            .font(.caption)
            .foregroundStyle(.red)
            .help(Text("\(failing.workflowName): \(failing.consecutiveFailures) Fehlschläge in Folge"))
        )
    }

    public func detailSection(for repository: RepoSnapshot, context: ModuleUIContext) -> AnyView? {
        guard let payload = repository.payload(ActionsPayload.self, for: moduleID) else { return nil }
        return AnyView(ActionsDetailSection(repository: repository, payload: payload, context: context))
    }

    public func tab(context: ModuleUIContext) -> ModuleTab? {
        let alerting = context.repositories.reduce(0) { total, repository in
            total + (repository.summaries[moduleID]?.counts["alerting"] ?? 0)
        }
        return ModuleTab(id: moduleID, title: title, systemImage: systemImage, badge: alerting, isAlert: alerting > 0,
                         content: ActionsTabView(module: module, context: context))
    }

    public func hasNews(in repository: RepoSnapshot, since date: Date) -> Bool {
        repository.payload(ActionsPayload.self, for: moduleID)?.workflowStates
            .contains { $0.isFailing && $0.latest.updatedAt > date } ?? false
    }
}

// MARK: - Zeilen

struct WorkflowStateRow: View {
    let state: WorkflowState
    let repositoryName: String?
    let context: ModuleUIContext

    var body: some View {
        Button {
            context.open(state.latest.url)
        } label: {
            HStack(alignment: .top, spacing: 8) {
                StatusIcon(state.isRunning ? .running : (state.current?.tone ?? .neutral))
                    .font(.callout)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(state.workflowName).lineLimit(1).truncationMode(.middle)
                        if let branch = state.branch { TagText(verbatim: branch).frame(maxWidth: 170, alignment: .leading) }
                        Spacer(minLength: 4)
                        RelativeTimeText(state.latest.updatedAt).font(.caption).foregroundStyle(.secondary)
                    }
                    HStack(spacing: 6) {
                        if let repositoryName { Text(repositoryName).foregroundStyle(.secondary) }
                        Text(state.latest.event).foregroundStyle(.tertiary)
                        if state.isFailing, let since = state.failingSince {
                            HStack(spacing: 2) {
                                Text("rot seit")
                                RelativeTimeText(since)
                                if state.consecutiveFailures > 1 { Text("(\(state.consecutiveFailures)×)") }
                            }
                            .foregroundStyle(.red)
                        }
                        if let rate = state.successRate {
                            Text(rate, format: .percent.precision(.fractionLength(0)))
                                .foregroundStyle(.tertiary)
                                .help(Text("Erfolgsquote der letzten Runs"))
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
            Button("Run im Browser öffnen") { context.open(state.latest.url) }
            Button("Link kopieren") { context.copy(state.latest.url) }
        }
    }
}

struct RunRow: View {
    let run: WorkflowRunSummary
    let context: ModuleUIContext

    var body: some View {
        Button {
            context.open(run.url)
        } label: {
            HStack(spacing: 8) {
                StatusIcon(run.outcome.tone)
                Text("\(run.workflowName) #\(run.runNumber)").lineLimit(1)
                if let branch = run.branch {
                    Text(branch).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 4)
                if run.outcome != .running {
                    Text(formattedDuration(run.duration)).foregroundStyle(.tertiary).monospacedDigit()
                }
                RelativeTimeText(run.startedAt).foregroundStyle(.secondary)
            }
            .font(.caption)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Reiter

/// Fehlgeschlagen · Läuft gerade · Zuletzt erfolgreich (Konzept 3.2).
struct ActionsTabView: View {
    let module: ActionsModule
    let context: ModuleUIContext
    @State private var showsSuccessful = false

    private struct Entry: Identifiable {
        let state: WorkflowState
        let repository: RepoSnapshot
        /// 0 = Standard-Branch, 1 = PR eines Menschen, 2 = Rest (z. B. Bot-PRs).
        let priority: Int
        var id: String { "\(repository.id)/\(state.id)" }
    }

    private var entries: [Entry] {
        let settings = context.settings
        return context.repositories.flatMap { repository -> [Entry] in
            guard let payload = repository.payload(ActionsPayload.self, for: ActionsModule.id) else { return [] }
            return payload.workflowStates.compactMap { state in
                let isDefault = state.branch == nil || state.branch == payload.defaultBranch
                if !settings.actionsShowAllBranches && !isDefault { return nil }
                if settings.actionsHiddenEvents.contains(state.latest.event) { return nil }
                if settings.actionsHideBotRuns, !isDefault,
                   !module.authorKind(of: state.latest, viewerLogin: context.viewerLogin).isPerson { return nil }
                guard context.matchesSearch(state.workflowName, repository.meta.nameWithOwner, state.branch) else { return nil }
                let isPerson = module.authorKind(of: state.latest, viewerLogin: context.viewerLogin).isPerson
                return Entry(state: state, repository: repository, priority: isDefault ? 0 : (isPerson ? 1 : 2))
            }
        }
    }

    var body: some View {
        let all = entries
        // Erst Standard-Branch, dann PRs von Menschen, dann Bot-PRs; jeweils zuletzt rot geworden zuerst.
        let failing = all.filter(\.state.isFailing).sorted {
            ($0.priority, -($0.state.failingSince ?? .distantPast).timeIntervalSince1970)
                < ($1.priority, -($1.state.failingSince ?? .distantPast).timeIntervalSince1970)
        }
        let running = all.filter { $0.state.isRunning && !$0.state.isFailing }
        let successful = all.filter { $0.state.current == .success && !$0.state.isRunning }
            .sorted { $0.state.latest.updatedAt > $1.state.latest.updatedAt }

        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Toggle("Alle Branches", isOn: binding(\.actionsShowAllBranches))
                Toggle("Bot-PRs ausblenden", isOn: binding(\.actionsHideBotRuns))
                Spacer()
            }
            .toggleStyle(.checkbox)
            .font(.caption)
            .padding(.horizontal, 14)
            .padding(.vertical, 6)
            Divider()

            if all.isEmpty {
                EmptyStateView("Keine Workflow-Runs", systemImage: "gearshape.2",
                               message: "Repos mit GitHub Actions erscheinen hier, sobald Runs bekannt sind.")
            } else {
                List {
                    if !failing.isEmpty {
                        Section { rows(failing) } header: { SectionTitle(String(localized: "Fehlgeschlagen"), count: failing.count) }
                    }
                    if !running.isEmpty {
                        Section { rows(running) } header: { SectionTitle(String(localized: "Läuft gerade"), count: running.count) }
                    }
                    if !successful.isEmpty {
                        Section {
                            if showsSuccessful || !context.searchText.isEmpty { rows(successful) }
                        } header: {
                            Button {
                                showsSuccessful.toggle()
                            } label: {
                                HStack(spacing: 6) {
                                    Image(systemName: showsSuccessful ? "chevron.down" : "chevron.right").font(.caption2)
                                    SectionTitle(String(localized: "Zuletzt erfolgreich"), count: successful.count)
                                    Spacer()
                                }
                                .contentShape(.rect)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
            }
        }
    }

    @ViewBuilder
    private func rows(_ entries: [Entry]) -> some View {
        ForEach(entries) { entry in
            WorkflowStateRow(state: entry.state, repositoryName: entry.repository.meta.nameWithOwner, context: context)
        }
    }

    private func binding(_ keyPath: WritableKeyPath<AppSettings, Bool>) -> Binding<Bool> {
        Binding(
            get: { context.settings[keyPath: keyPath] },
            set: { value in context.updateSettings { $0[keyPath: keyPath] = value } }
        )
    }
}

// MARK: - Detail

struct ActionsDetailSection: View {
    let repository: RepoSnapshot
    let payload: ActionsPayload
    let context: ModuleUIContext

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !payload.hasWorkflows && payload.headStatus == nil {
                Text("Keine GitHub-Actions-Workflows in diesem Repo.").foregroundStyle(.secondary).font(.callout)
            } else {
                HStack(spacing: 6) {
                    StatusIcon(StatusTone(payload.headStatus))
                    Text("Letzter Commit auf \(payload.defaultBranch ?? "–")")
                    if payload.recentRunsFetchedAt == nil {
                        Text("· nur Stand des letzten Commits").foregroundStyle(.tertiary)
                    }
                }
                .font(.caption)

                ForEach(payload.workflowStates) { state in
                    WorkflowStateRow(state: state, repositoryName: nil, context: context)
                    Divider()
                }

                if !payload.recentRuns.isEmpty {
                    Text("Letzte Runs").font(.caption).foregroundStyle(.secondary)
                    ForEach(payload.recentRuns.prefix(10)) { run in
                        RunRow(run: run, context: context)
                    }
                    Link("Alle Runs auf GitHub", destination: repository.meta.url.appending(path: "actions"))
                        .font(.caption)
                }
            }
        }
    }
}
