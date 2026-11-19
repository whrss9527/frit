import Foundation
import ServiceManagement

/// Login item management: Meno base with Proxi `reregister()`.
///
/// Uses `SMAppService` (macOS 13+). Apps call `set(true)` in their preferences
/// and `reregister()` after the bundle has been moved or renamed.
public enum LoginItem {
    /// Whether the app is currently registered to launch at login.
    public static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    /// Whether the login item is registered but requires the user to approve
    /// it in System Settings → General → Login Items.
    public static var requiresApproval: Bool {
        if #available(macOS 14.0, *) {
            return SMAppService.mainApp.status == .requiresApproval
        }
        return false
    }

    /// Registers or unregisters the app as a login item.
    /// - Returns: An error description, or `nil` on success.
    @discardableResult
    public static func set(_ enabled: Bool) -> String? {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    /// Re-registers after the app has been relocated or renamed so that the
    /// login item points to the new path. Does nothing on failure.
    public static func reregister() {
        try? SMAppService.mainApp.unregister()
        do {
            try SMAppService.mainApp.register()
        } catch {
            // The user can re-enable the setting manually.
        }
    }

    /// Opens System Settings to the Login Items pane so the user can review
    /// or approve the login item.
    public static func openSystemSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}