import SwiftUI

@main
struct RepoWatchApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        // Eine Szene braucht jede App. Das Einstellungsfenster verwaltet `SettingsWindowController`
        // selbst, weil eine App ohne Dock-Icon das Szenen-Fenster nicht zuverlässig nach vorn holt.
        Settings {
            EmptyView()
        }
    }
}
