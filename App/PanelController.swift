import AppKit
import SwiftUI
import os

private let logger = Logger(subsystem: "de.pmoscode.repowatch", category: "Panel")

/// Panel unter dem Menüleisten-Symbol (Konzept 3.1, Entscheidung E6).
///
/// - nicht aktivierend: andere Apps behalten den Fokus, Texteingabe im Panel funktioniert trotzdem
/// - schließt bei Klick daneben, bei Esc und wenn es den Fokus verliert
/// - lässt sich per Code öffnen (Grundlage für einen späteren globalen Hotkey)
@MainActor
final class PanelController: NSObject, NSWindowDelegate {
    var onVisibilityChange: ((Bool) -> Void)?

    private let panel: KeyablePanel
    /// Fragt SwiftUI nach der idealen Größe des Inhalts. `fittingSize` liefert innerhalb
    /// von `NSGlassEffectView` 0 × 0, deshalb wird über den Hosting-Controller gemessen.
    private let contentSize: (CGSize) -> CGSize
    private var outsideClickMonitor: Any?
    private static let gap: CGFloat = 6
    private static let screenMargin: CGFloat = 8

    init<Content: View>(rootView: Content) {
        let hostingController = NSHostingController(rootView: rootView)
        hostingController.sizingOptions = []
        contentSize = { hostingController.sizeThatFits(in: $0) }

        let glass = NSGlassEffectView()
        glass.cornerRadius = 18
        glass.contentView = hostingController.view
        #if DEBUG
        // `--no-glass`: ohne Glas-Ebene, um Snapshots mit echten Farben zu vergleichen.
        let usesGlass = !ProcessInfo.processInfo.arguments.contains("--no-glass")
        #else
        let usesGlass = true
        #endif

        panel = KeyablePanel(
            contentRect: NSRect(origin: .zero, size: CGSize(width: 400, height: 560)),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        super.init()

        if usesGlass {
            panel.contentView = glass
        } else {
            hostingController.view.wantsLayer = true
            hostingController.view.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
            panel.contentView = hostingController.view
        }
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.isMovable = false
        panel.animationBehavior = .utilityWindow
        panel.delegate = self
        panel.onEscape = { [weak self] in self?.close() }
    }

    var isVisible: Bool { panel.isVisible }

    func toggle(below anchor: NSRect) {
        isVisible ? close() : show(below: anchor)
    }

    func show(below anchor: NSRect) {
        position(below: anchor)
        panel.makeKeyAndOrderFront(nil)
        startOutsideClickMonitor()
        onVisibilityChange?(true)
    }

    func close() {
        guard panel.isVisible else { return }
        panel.orderOut(nil)
        stopOutsideClickMonitor()
        onVisibilityChange?(false)
    }

    #if DEBUG
    /// Entwicklung: Inhalt des Panels für Snapshots (ohne Glas-Unschärfe, die rendert nur der WindowServer).
    var contentView: NSView? { panel.contentView }
    #endif

    // MARK: NSWindowDelegate

    func windowDidResignKey(_ notification: Notification) {
        close()
    }

    // MARK: Platzierung

    private func position(below anchor: NSRect) {
        let screen = NSScreen.screens.first { $0.frame.intersects(anchor) } ?? NSScreen.main
        let visible = screen?.visibleFrame ?? anchor
        let size = contentSize(visible.size)

        var x = anchor.midX - size.width / 2
        x = min(max(x, visible.minX + Self.screenMargin), visible.maxX - size.width - Self.screenMargin)
        let y = anchor.minY - size.height - Self.gap

        panel.setFrame(NSRect(x: x, y: y, width: size.width, height: size.height), display: true)
        logger.info("Panel geöffnet: \(self.panel.frame.debugDescription, privacy: .public)")
    }

    // MARK: Klick daneben

    private func startOutsideClickMonitor() {
        stopOutsideClickMonitor()
        // Globale Maus-Monitore brauchen keine Bedienungshilfen-Freigabe (nur Tastatur-Monitore).
        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        ) { [weak self] _ in
            Task { @MainActor in self?.close() }
        }
    }

    private func stopOutsideClickMonitor() {
        if let outsideClickMonitor {
            NSEvent.removeMonitor(outsideClickMonitor)
        }
        outsideClickMonitor = nil
    }
}

/// Randloses Panel, das trotzdem Tastatureingaben annimmt.
final class KeyablePanel: NSPanel {
    var onEscape: (() -> Void)?

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func cancelOperation(_ sender: Any?) {
        onEscape?()
    }
}
