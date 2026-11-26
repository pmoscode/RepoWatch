import AppKit
import Features
import SwiftUI

/// Eigenes Einstellungsfenster (Konzept 3.3).
///
/// Bewusst kein `Settings`-Szenen-Fenster: Eine App ohne Dock-Icon (`LSUIElement`) kann das aus
/// einem `NSPanel` heraus nicht zuverlässig nach vorn holen.
@MainActor
final class SettingsWindowController {
    private let model: AppModel
    private var window: NSWindow?

    init(model: AppModel) {
        self.model = model
    }

    func show() {
        let window = window ?? makeWindow()
        self.window = window
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
    }

    var contentView: NSView? { window?.contentView }

    private func makeWindow() -> NSWindow {
        let window = NSWindow(contentViewController: NSHostingController(rootView: SettingsView(model: model)))
        window.title = String(localized: "RepoWatch – Einstellungen")
        window.styleMask = [.titled, .closable, .miniaturizable]
        window.isReleasedWhenClosed = false
        window.center()
        return window
    }
}
