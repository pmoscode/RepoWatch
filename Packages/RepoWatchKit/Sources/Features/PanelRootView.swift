import DesignSystem
import Domain
import ModuleUIKit
import SwiftUI

/// Reiter des Panels: Übersicht plus ein Reiter je Modul (Konzept 3.2).
enum PanelTab: Hashable {
    case overview
    case module(ModuleID)
}

/// Inhalt des Menüleisten-Panels (Konzept 3.2).
public struct PanelRootView: View {
    private let model: AppModel
    private let onQuit: () -> Void
    private let onOpenSettings: () -> Void

    @State private var tab: PanelTab = .overview
    @State private var detailRepositoryID: String?
    @State private var isSearching = false
    @FocusState private var searchFocused: Bool

    public init(model: AppModel, onQuit: @escaping () -> Void, onOpenSettings: @escaping () -> Void) {
        self.model = model
        self.onQuit = onQuit
        self.onOpenSettings = onOpenSettings
    }

    public var body: some View {
        VStack(spacing: 0) {
            if model.isSignedIn {
                header
                if let id = detailRepositoryID, let repository = model.ui.repository(id: id) {
                    Divider()
                    RepositoryDetailView(repository: repository, model: model) {
                        withAnimation(.snappy) { detailRepositoryID = nil }
                    }
                    .transition(.move(edge: .trailing).combined(with: .opacity))
                } else {
                    tabBar
                    Divider()
                    content
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            } else {
                SignInView(model: model)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            Divider()
            footer
        }
        .frame(width: 400, height: 600)
        .onChange(of: model.requestedRepositoryID) { _, id in
            guard let id else { return }
            withAnimation(.snappy) { detailRepositoryID = id }
            model.requestedRepositoryID = nil
        }
        .onAppear(perform: applyDebugRequests)
        .onChange(of: model.repositories.count) { _, _ in applyDebugRequests() }
        .background {
            // Tastenkürzel ohne sichtbare Knöpfe (Konzept 3.2).
            Group {
                Button("Suchen") { startSearch() }.keyboardShortcut("f")
                Button("Zurück") { detailRepositoryID = nil }.keyboardShortcut("[")
            }
            .opacity(0)
            .allowsHitTesting(false)
        }
    }

    // MARK: Kopf

    private var header: some View {
        HStack(spacing: 8) {
            if isSearching {
                HStack(spacing: 4) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("Suchen", text: Bindable(model.ui).searchText)
                        .textFieldStyle(.plain)
                        .focused($searchFocused)
                        .onExitCommand(perform: endSearch)
                    Button {
                        endSearch()
                    } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.borderless)
                    .help("Suche schließen")
                    .accessibilityLabel("Suche schließen")
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(.quaternary, in: .capsule)
            } else {
                accountMenu
                Spacer()
                Button(action: startSearch) {
                    Image(systemName: "magnifyingglass")
                }
                .buttonStyle(.borderless)
                .help("Suchen (⌘F)")
                .accessibilityLabel("Suchen")
            }
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
            .accessibilityLabel("Aktualisieren")
            .disabled(model.isSyncing)
            Button(action: onOpenSettings) {
                Image(systemName: "gearshape")
            }
            .buttonStyle(.borderless)
            .keyboardShortcut(",")
            .help("Einstellungen (⌘,)")
            .accessibilityLabel("Einstellungen")
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
                Text(login).font(.headline)
            } icon: {
                Image(systemName: "person.crop.circle").foregroundStyle(.secondary)
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

    private func startSearch() {
        isSearching = true
        searchFocused = true
    }

    private func endSearch() {
        model.ui.searchText = ""
        isSearching = false
    }

    // MARK: Reiter

    private var moduleTabs: [ModuleTab] {
        model.enabledModuleUIs.compactMap { $0.tab(context: model.ui) }
    }

    private var tabBar: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 4) {
                TabButton(title: String(localized: "Übersicht"), systemImage: "square.grid.2x2", badge: nil,
                          isAlert: false, isSelected: tab == .overview) { tab = .overview }
                ForEach(moduleTabs) { moduleTab in
                    TabButton(title: moduleTab.title, systemImage: moduleTab.systemImage, badge: moduleTab.badge,
                              isAlert: moduleTab.isAlert, isSelected: tab == .module(moduleTab.id)) {
                        tab = .module(moduleTab.id)
                    }
                }
            }
            .padding(.horizontal, 10)
            .padding(.bottom, 8)
        }
        .scrollIndicators(.never)
    }

    @ViewBuilder
    private var content: some View {
        switch tab {
        case .overview:
            if model.syncState != nil {
                OverviewView(model: model) { id in
                    withAnimation(.snappy) { detailRepositoryID = id }
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
        case .module(let id):
            if let moduleTab = moduleTabs.first(where: { $0.id == id }) {
                moduleTab.content
            } else {
                Color.clear.onAppear { tab = .overview }
            }
        }
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

    // MARK: Debug

    private func applyDebugRequests() {
        if let requested = model.debugInitialTab {
            tab = requested == "overview" ? .overview : .module(ModuleID(requested))
            model.debugInitialTab = nil
        }
        if let name = model.debugInitialRepository,
           let repository = model.repositories.first(where: { $0.meta.nameWithOwner == name || String($0.meta.name) == name }) {
            detailRepositoryID = repository.id
            model.debugInitialRepository = nil
        }
    }
}

/// Ein Reiter-Knopf mit Zahl (Konzept 3.2).
private struct TabButton: View {
    let title: String
    let systemImage: String
    let badge: Int?
    let isAlert: Bool
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: systemImage)
                // Platz sparen: nur der gewählte Reiter zeigt seinen Titel (fünf Reiter auf 400 pt).
                if isSelected { Text(title) }
                if let badge, badge > 0 {
                    Text(badge, format: .number)
                        .font(.caption2.weight(.semibold).monospacedDigit())
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(isAlert ? AnyShapeStyle(Color.red) : AnyShapeStyle(.quaternary), in: .capsule)
                        .foregroundStyle(isAlert ? Color.white : .primary)
                }
            }
            .font(.callout)
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(isSelected ? AnyShapeStyle(Color.accentColor.opacity(0.22)) : AnyShapeStyle(.clear), in: .capsule)
            .contentShape(.capsule)
        }
        .buttonStyle(.plain)
        .foregroundStyle(isSelected ? .primary : .secondary)
        .help(title)
        .accessibilityLabel(Text(title))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}
