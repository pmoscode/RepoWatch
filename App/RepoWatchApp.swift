import SwiftUI

@main
struct RepoWatchApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        // Platzhalter; das Einstellungsfenster folgt in Phase 4 (Konzept 3.3).
        Settings {
            Text("Einstellungen folgen.")
                .padding(40)
        }
    }
}
