import AppKit
import Features
import SwiftUI

/// Composition Root: erzeugt Modell, Menüleisten-Symbol und Panel und verdrahtet sie.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var model: AppModel?
    private var statusItemController: StatusItemController?
    private var panelController: PanelController?
    private var settingsWindowController: SettingsWindowController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        #if DEBUG
        // `--appearance light|dark`: Erscheinungsbild für Snapshots erzwingen (vor dem Anlegen der Fenster).
        let arguments = ProcessInfo.processInfo.arguments
        if let index = arguments.firstIndex(of: "--appearance"), arguments.indices.contains(index + 1) {
            NSApp.appearance = NSAppearance(named: arguments[index + 1] == "light" ? .aqua : .darkAqua)
        }
        #endif
        #if DEBUG
        let configuration = AppConfiguration.live(allowEnvironmentToken: true)
        #else
        let configuration = AppConfiguration.live(allowEnvironmentToken: false)
        #endif
        let model = AppModel(configuration: configuration)
        let settingsWindowController = SettingsWindowController(model: model)
        var openSettings: () -> Void = {}
        let panelController = PanelController(
            rootView: PanelRootView(model: model, onQuit: { NSApp.terminate(nil) }, onOpenSettings: { openSettings() })
        )
        openSettings = { [weak panelController, weak settingsWindowController] in
            panelController?.close()
            settingsWindowController?.show()
        }
        let statusItemController = StatusItemController(model: model)
        statusItemController.onToggle = { [weak panelController, weak statusItemController] in
            guard let panelController, let anchor = statusItemController?.anchorFrame else { return }
            panelController.toggle(below: anchor)
        }
        panelController.onVisibilityChange = { [weak statusItemController, weak model] isVisible in
            statusItemController?.setHighlighted(isVisible)
            if isVisible { model?.panelDidOpen() } else { model?.panelDidClose() }
        }

        self.model = model
        self.panelController = panelController
        self.statusItemController = statusItemController
        self.settingsWindowController = settingsWindowController
        statusItemController.onOpenSettings = openSettings

        model.start()

        #if DEBUG
        runDebugLaunchArguments(model: model, panelController: panelController,
                                statusItemController: statusItemController, settings: settingsWindowController)
        #endif
    }

    #if DEBUG
    /// Entwicklung und Screenshots:
    /// - `--show-panel` öffnet das Panel nach dem Start, `--tab <id>` / `--repo <name>` wählen die Ansicht
    /// - `--snapshot <name>` speichert nach 7 s ein Bild in den Sandbox-Container (`tmp/<name>.png`)
    /// - `--show-settings [<reiter>]` öffnet stattdessen das Einstellungsfenster
    private func runDebugLaunchArguments(
        model: AppModel,
        panelController: PanelController,
        statusItemController: StatusItemController,
        settings: SettingsWindowController
    ) {
        let arguments = ProcessInfo.processInfo.arguments
        func value(after flag: String) -> String? {
            guard let index = arguments.firstIndex(of: flag), arguments.indices.contains(index + 1),
                  !arguments[index + 1].hasPrefix("--") else { return nil }
            return arguments[index + 1]
        }
        model.debugInitialTab = value(after: "--tab")
        model.debugInitialRepository = value(after: "--repo")
        let snapshotName = arguments.contains("--snapshot") ? (value(after: "--snapshot") ?? "panel-snapshot") : nil

        Task { @MainActor [weak panelController, weak statusItemController, weak settings] in
            try? await Task.sleep(for: .milliseconds(500))
            var view: NSView?
            if arguments.contains("--show-settings") {
                settings?.show()
                view = settings?.contentView
            } else if arguments.contains("--show-panel") {
                guard let panelController, let anchor = statusItemController?.anchorFrame else {
                    NSLog("RepoWatch: --show-panel ohne Anker (Symbol nicht sichtbar?)")
                    return
                }
                panelController.show(below: anchor)
                view = panelController.contentView
            }
            guard let snapshotName, let view else { return }
            try? await Task.sleep(for: .seconds(7))
            let url = FileManager.default.temporaryDirectory.appending(path: "\(snapshotName).png")
            guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
            view.cacheDisplay(in: view.bounds, to: bitmap)
            do {
                try bitmap.representation(using: .png, properties: [:])?.write(to: url)
                NSLog("RepoWatch: Snapshot unter %@", url.path)
            } catch {
                NSLog("RepoWatch: Snapshot fehlgeschlagen: %@", error.localizedDescription)
            }
        }
    }
    #endif
}
