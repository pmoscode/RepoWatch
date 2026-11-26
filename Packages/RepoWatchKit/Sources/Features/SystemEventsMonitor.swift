import AppKit
import Network

/// Meldet Ereignisse, nach denen sich ein Sync lohnt (Konzept 4.2):
/// Aufwachen aus dem Ruhezustand und Netzwerk wieder verfügbar.
@MainActor
final class SystemEventsMonitor {
    private let onWake: @MainActor () -> Void
    private var wakeObserver: NSObjectProtocol?
    private let pathMonitor = NWPathMonitor()
    private var wasOffline = false

    init(onWake: @escaping @MainActor () -> Void) {
        self.onWake = onWake

        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.onWake() }
        }

        pathMonitor.pathUpdateHandler = { [weak self] path in
            let isOnline = path.status == .satisfied
            Task { @MainActor in self?.networkChanged(isOnline: isOnline) }
        }
        pathMonitor.start(queue: DispatchQueue(label: "de.pmoscode.repowatch.network"))
    }

    isolated deinit {
        if let wakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver)
        }
        pathMonitor.cancel()
    }

    private func networkChanged(isOnline: Bool) {
        defer { wasOffline = !isOnline }
        if isOnline && wasOffline {
            onWake()
        }
    }
}
