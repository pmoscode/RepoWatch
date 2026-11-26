import AppKit
import Domain
import Foundation
import GitHubAPI
import Observation
import Persistence
import SwiftUI

/// Zugriffe, die Module für Daten auf Anforderung brauchen (Nachladen, Sparkline, Ereignisse).
public struct ModuleServices: Sendable {
    public let graphQL: GraphQLClient
    public let rest: RESTClient

    public init(graphQL: GraphQLClient, rest: RESTClient) {
        self.graphQL = graphQL
        self.rest = rest
    }
}

/// Alles, was die Oberfläche der Module braucht: aktueller Stand, Einstellungen, Suche, Aktionen.
/// Wird vom `AppModel` gepflegt.
@MainActor
@Observable
public final class ModuleUIContext {
    public var repositories: [RepoSnapshot] = []
    public var viewerLogin = ""
    public var settings = AppSettings()
    public var seen = SeenState()
    /// Suchtext aus dem Kopfbereich; Module filtern ihre Reiter danach.
    public var searchText = ""
    public let services: ModuleServices?

    // Aktionen, gesetzt vom AppModel.
    public var showRepositoryAction: (String) -> Void = { _ in }
    public var markSeenAction: (String) -> Void = { _ in }
    public var toggleFavoriteAction: (String) -> Void = { _ in }
    public var updateSettingsAction: ((inout AppSettings) -> Void) -> Void = { _ in }

    public init(services: ModuleServices?) {
        self.services = services
    }

    public func repository(id: String) -> RepoSnapshot? {
        repositories.first { $0.id == id }
    }

    public func open(_ url: URL) {
        NSWorkspace.shared.open(url)
    }

    public func copy(_ url: URL) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(url.absoluteString, forType: .string)
    }

    public func showRepository(_ id: String) { showRepositoryAction(id) }
    public func markSeen(_ repositoryID: String) { markSeenAction(repositoryID) }
    public func toggleFavorite(_ nameWithOwner: String) { toggleFavoriteAction(nameWithOwner) }
    public func updateSettings(_ change: (inout AppSettings) -> Void) { updateSettingsAction(change) }

    /// Zeitpunkt, ab dem etwas in diesem Repo als „neu“ gilt (Konzept 3.2).
    public func newSince(repositoryID: String) -> Date? {
        [seen.panelOpenedAt, seen.repositorySeenAt[repositoryID]].compactMap { $0 }.max()
    }

    public func isNew(_ date: Date, repositoryID: String) -> Bool {
        guard let since = newSince(repositoryID: repositoryID) else { return false }
        return date > since
    }

    /// Passt `text` zur Suche? Leere Suche passt immer.
    public func matchesSearch(_ texts: String?...) -> Bool {
        let query = searchText.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return true }
        return texts.contains { $0?.localizedCaseInsensitiveContains(query) == true }
    }
}

/// Ein Reiter im Panel (Konzept 3.2).
public struct ModuleTab: Identifiable {
    public let id: ModuleID
    public let title: String
    public let systemImage: String
    /// Zahl am Reiter, z. B. offene Issues.
    public let badge: Int?
    /// Zahl rot darstellen (Alarm).
    public let isAlert: Bool
    public let content: AnyView

    public init(id: ModuleID, title: String, systemImage: String, badge: Int?, isAlert: Bool = false, content: some View) {
        self.id = id
        self.title = title
        self.systemImage = systemImage
        self.badge = badge
        self.isAlert = isAlert
        self.content = AnyView(content)
    }
}

/// Darstellung eines Moduls (Konzept 9.2, Punkt 4). Jede Funktion ist optional.
@MainActor
public protocol ModuleUI {
    var moduleID: ModuleID { get }
    var title: String { get }
    var systemImage: String { get }

    /// Kleines Status-Symbol in der ersten Zeile der Repo-Zeile (z. B. CI-Status, Aktivität).
    func rowBadge(for repository: RepoSnapshot, context: ModuleUIContext) -> AnyView?
    /// Zusatzinfo in der zweiten Zeile der Repo-Zeile (z. B. „◎ 4“).
    func rowAccessory(for repository: RepoSnapshot, context: ModuleUIContext) -> AnyView?
    /// Abschnitt in der Detailansicht eines Repos.
    func detailSection(for repository: RepoSnapshot, context: ModuleUIContext) -> AnyView?
    /// Eigener Reiter im Panel.
    func tab(context: ModuleUIContext) -> ModuleTab?
    /// Gibt es in diesem Repo seit `date` etwas Neues? (Markierung in der Übersicht)
    func hasNews(in repository: RepoSnapshot, since date: Date) -> Bool
}

extension ModuleUI {
    public func rowBadge(for repository: RepoSnapshot, context: ModuleUIContext) -> AnyView? { nil }
    public func rowAccessory(for repository: RepoSnapshot, context: ModuleUIContext) -> AnyView? { nil }
    public func detailSection(for repository: RepoSnapshot, context: ModuleUIContext) -> AnyView? { nil }
    public func tab(context: ModuleUIContext) -> ModuleTab? { nil }
    public func hasNews(in repository: RepoSnapshot, since date: Date) -> Bool { false }
}
