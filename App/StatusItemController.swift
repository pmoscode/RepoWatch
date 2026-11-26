import AppKit
import Observation
import Features

/// Symbol in der Menüleiste (Konzept 3.1).
///
/// Linksklick öffnet/schließt das Panel, Rechtsklick zeigt ein kleines Menü.
@MainActor
final class StatusItemController: NSObject {
    var onToggle: (() -> Void)?

    private let statusItem: NSStatusItem
    private let model: AppModel

    init(model: AppModel) {
        self.model = model
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()

        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "binoculars", accessibilityDescription: "RepoWatch")
            button.image?.isTemplate = true
            button.imagePosition = .imageLeading
            button.target = self
            button.action = #selector(handleClick(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
        observeModel()
    }

    /// Rahmen des Symbols in Bildschirmkoordinaten, um das Panel darunter zu platzieren.
    var anchorFrame: NSRect? {
        guard let button = statusItem.button, let window = button.window else { return nil }
        return window.convertToScreen(button.convert(button.bounds, to: nil))
    }

    func setHighlighted(_ highlighted: Bool) {
        statusItem.button?.highlight(highlighted)
    }

    // MARK: Klicks

    @objc private func handleClick(_ sender: NSStatusBarButton) {
        if NSApp.currentEvent?.type == .rightMouseUp {
            showMenu()
        } else {
            onToggle?()
        }
    }

    private func showMenu() {
        let menu = NSMenu()
        menu.addItem(withTitle: String(localized: "Aktualisieren"), action: #selector(refresh), keyEquivalent: "r")
            .target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: String(localized: "RepoWatch beenden"), action: #selector(quit), keyEquivalent: "q")
            .target = self
        guard let button = statusItem.button else { return }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.height + 4), in: button)
    }

    @objc private func refresh() { model.refresh() }
    @objc private func quit() { NSApp.terminate(nil) }

    // MARK: Anzeige

    /// Phase 0: Anzahl der Repos neben dem Symbol. Die Anzeige-Modi folgen in Phase 4.
    private func observeModel() {
        withObservationTracking {
            updateButton()
        } onChange: { [weak self] in
            Task { @MainActor in self?.observeModel() }
        }
    }

    private func updateButton() {
        guard let button = statusItem.button else { return }
        guard model.isSignedIn else {
            button.title = ""
            button.appearsDisabled = true
            button.toolTip = String(localized: "RepoWatch – nicht angemeldet")
            return
        }
        switch model.state {
        case .failed(let message):
            button.title = ""
            button.appearsDisabled = true
            button.toolTip = message
        case .idle, .loading, .loaded:
            let count = model.visibleRepositories.count
            button.title = model.inventory == nil ? "" : " \(count)"
            button.appearsDisabled = false
            button.toolTip = model.inventory == nil
                ? "RepoWatch"
                : String(localized: "RepoWatch – \(count) Repositories")
        }
    }
}
