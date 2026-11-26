import Domain
import Foundation
import ModuleUIKit
import Testing
@testable import Features

@MainActor
@Suite("Oberfläche")
struct FeaturesTests {
    @Test("Preview-Daten lassen sich aufbauen und anzeigen")
    func previewData() {
        let model = PreviewData.model()
        #expect(model.isSignedIn)
        #expect(model.repositories.count == 5)
        #expect(model.repositories.allSatisfy { $0.payloads.count == 4 })
        // Alle vier Module liefern einen Reiter.
        #expect(model.enabledModuleUIs.compactMap { $0.tab(context: model.ui) }.count == 4)
    }

    @Test("Menüleiste: Alarm, Zähler je Modus, abschaltbar")
    func menuBarIndicator() {
        let model = PreviewData.model()
        #expect(model.menuBarIndicator.showsAlarm)

        model.updateSettings { $0.menuBarMode = .openItems }
        let expected = model.repositories.reduce(0) { $0 + $1.meta.openIssueCount + $1.meta.openPullRequestCount }
        #expect(expected > 0)
        #expect(model.menuBarIndicator.count == expected)

        model.updateSettings { $0.alarmDotEnabled = false }
        #expect(!model.menuBarIndicator.showsAlarm)
    }

    @Test("Favoriten und abgeschaltete Module")
    func settingsEffects() {
        let model = PreviewData.model()
        model.toggleFavorite("octocat/homelab")
        #expect(model.settings.isFavorite("octocat/homelab"))
        model.updateSettings { $0.disabledModules = ["activity"] }
        #expect(!model.enabledModuleUIs.contains { $0.moduleID == ModuleID("activity") })
    }

    @Test("Einstellungen: fehlende Felder bekommen Standardwerte")
    func settingsDecodingDefaults() throws {
        let settings = try JSONDecoder().decode(AppSettings.self, from: Data(#"{"favorites":["a/b"]}"#.utf8))
        #expect(settings.favorites == ["a/b"])
        #expect(settings.issuesHideBotIssues)
        #expect(settings.activeIntervalMinutes == 5)
    }
}
