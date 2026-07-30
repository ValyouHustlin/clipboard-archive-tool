import ClipboardArchiveCore
import Foundation
import ServiceManagement

/// Thin, main-actor wrapper over `SMAppService.mainApp` (Slice 9). All
/// decisions and copy live in the testable `ClipboardLoginItemState`; this
/// type only performs the real reads and the explicit, user-initiated
/// register/unregister calls. Nothing here runs automatically: the app
/// NEVER auto-enables launch-at-login, and the default stays off.
@MainActor
final class LoginItemManager {
    /// The real registration state, read fresh on every access (the card
    /// refreshes it whenever the Settings window shows).
    var state: ClipboardLoginItemState {
        ClipboardLoginItemState(
            smAppServiceStatusRawValue: SMAppService.mainApp.status.rawValue
        )
    }

    /// Registers or unregisters the main app as a login item. Errors are
    /// thrown to the caller so Settings can surface them honestly (for
    /// example, when the binary is not in a normal app location).
    func setEnabled(_ enabled: Bool) throws {
        if enabled {
            try SMAppService.mainApp.register()
        } else {
            try SMAppService.mainApp.unregister()
        }
    }

    /// Opens System Settings › General › Login Items (used for the
    /// `.requiresApproval` state). User-initiated navigation, not network.
    func openLoginItemsSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}
