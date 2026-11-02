import Observation
import ServiceManagement
import os

/// Settings → General: open Blask Sync when you log in, as a login item registered with `SMAppService`.
/// The system owns the setting (the user can also change it in System Settings → General → Login Items),
/// so it's read back from there rather than saved by the app.
@MainActor
@Observable
final class LaunchAtLogin {
    private(set) var status = SMAppService.mainApp.status
    private(set) var errorMessage: String?

    private static let logger = Logger(subsystem: "local.blasksync", category: "login-item")

    var isEnabled: Bool {
        get { status == .enabled || status == .requiresApproval }
        set { setEnabled(newValue) }
    }

    /// Registered, but switched off in System Settings → Login Items.
    var needsApproval: Bool { status == .requiresApproval }

    /// Picks up changes made in System Settings while the app was running.
    func refresh() {
        status = SMAppService.mainApp.status
    }

    func openSystemSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }

    private func setEnabled(_ enabled: Bool) {
        errorMessage = nil
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            Self.logger.error("Couldn't change launch at login: \(error)")
            errorMessage = error.localizedDescription
        }
        refresh()
    }
}
