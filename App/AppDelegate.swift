import AppKit
import Features
import SwiftUI

/// Composition Root: erzeugt Modell, Menüleisten-Symbol und Panel und verdrahtet sie.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var model: AppModel?
    private var statusItemController: StatusItemController?
    private var panelController: PanelController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let model = AppModel()
        let panelController = PanelController(
            rootView: PanelRootView(model: model, onQuit: { NSApp.terminate(nil) })
        )
        let statusItemController = StatusItemController(model: model)
        statusItemController.onToggle = { [weak panelController, weak statusItemController] in
            guard let panelController, let anchor = statusItemController?.anchorFrame else { return }
            panelController.toggle(below: anchor)
        }
        panelController.onVisibilityChange = { [weak statusItemController] isVisible in
            statusItemController?.setHighlighted(isVisible)
        }

        self.model = model
        self.panelController = panelController
        self.statusItemController = statusItemController

        model.refresh()

        #if DEBUG
        // Entwicklung: `--show-panel` öffnet das Panel direkt nach dem Start (z. B. für Screenshots).
        if ProcessInfo.processInfo.arguments.contains("--show-panel") {
            Task { @MainActor [weak panelController, weak statusItemController] in
                try? await Task.sleep(for: .milliseconds(500))
                guard let panelController, let anchor = statusItemController?.anchorFrame else {
                    NSLog("RepoWatch: --show-panel ohne Anker (Symbol nicht sichtbar?)")
                    return
                }
                panelController.show(below: anchor)

                // `--snapshot`: nach dem Laden ein Bild des Panels in den Sandbox-Container schreiben.
                if ProcessInfo.processInfo.arguments.contains("--snapshot") {
                    try? await Task.sleep(for: .seconds(6))
                    let url = FileManager.default.temporaryDirectory.appending(path: "panel-snapshot.png")
                    do {
                        try panelController.writeSnapshot(to: url)
                        NSLog("RepoWatch: Snapshot unter %@", url.path)
                    } catch {
                        NSLog("RepoWatch: Snapshot fehlgeschlagen: %@", error.localizedDescription)
                    }
                }
            }
        }
        #endif
    }
}
