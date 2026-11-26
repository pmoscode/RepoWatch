import Observation
import ServiceManagement
import os

/// „Bei Anmeldung starten“ über `SMAppService.mainApp` (Plan Phase 5).
///
/// Der Zustand liegt bei macOS (Systemeinstellungen → Allgemein → Anmeldeobjekte); die App liest ihn
/// nur aus und speichert ihn nicht selbst, damit beide Stellen nie auseinanderlaufen.
@MainActor
@Observable
public final class LoginItemController {
    public private(set) var status: SMAppService.Status
    public private(set) var lastError: String?
    private let logger = Logger(subsystem: "de.pmoscode.repowatch", category: "LoginItem")

    public init() {
        status = SMAppService.mainApp.status
    }

    public var isEnabled: Bool { status == .enabled || status == .requiresApproval }
    /// Registriert, aber in den Systemeinstellungen noch nicht erlaubt.
    public var requiresApproval: Bool { status == .requiresApproval }

    public func setEnabled(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            lastError = nil
        } catch {
            logger.error("Anmeldeobjekt nicht geändert: \(error.localizedDescription, privacy: .public)")
            lastError = error.localizedDescription
        }
        refresh()
    }

    public func refresh() {
        status = SMAppService.mainApp.status
    }

    public func openSystemSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}
