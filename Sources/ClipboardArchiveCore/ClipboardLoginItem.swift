import Foundation

/// Pure, testable model for the launch-at-login control (Slice 9).
///
/// The menu bar app reads the real state from `SMAppService.mainApp.status`
/// (ServiceManagement, macOS 13+) and maps the raw value through this enum;
/// every user-facing string and toggle decision lives here so the behavior
/// is unit-testable without a login-item registration. The app NEVER
/// auto-enables the login item — registration only happens from an explicit
/// user click on the Settings toggle.
///
/// This is separate from the LaunchAgent that `install.sh` writes
/// (`~/Library/LaunchAgents/app.clipboardarchive.plist`). Both mechanisms
/// start the same app; enabling both would race two launches into the
/// single-instance lock. `docs/INSTALL.md` documents choosing one.
public enum ClipboardLoginItemState: Equatable, Sendable {
    /// SMAppService raw value 0: not registered — the app starts only when
    /// opened manually (the default).
    case notRegistered
    /// SMAppService raw value 1: registered and approved.
    case enabled
    /// SMAppService raw value 2: registered, but macOS wants the user to
    /// approve it in System Settings › General › Login Items.
    case requiresApproval
    /// SMAppService raw value 3: the service cannot be found — typical when
    /// the binary runs outside a normal `.app` location (development
    /// builds, bare SwiftPM executables). Surfaced honestly, never hidden.
    case notFound
    /// A raw value this build does not know (a future macOS).
    case unknown(Int)

    public init(smAppServiceStatusRawValue rawValue: Int) {
        switch rawValue {
        case 0:
            self = .notRegistered
        case 1:
            self = .enabled
        case 2:
            self = .requiresApproval
        case 3:
            self = .notFound
        default:
            self = .unknown(rawValue)
        }
    }

    /// Whether the Settings checkbox renders checked. `requiresApproval`
    /// counts as on: the user asked for it and macOS is holding approval —
    /// unchecking is still how they withdraw the request.
    public var reflectsToggleOn: Bool {
        switch self {
        case .enabled, .requiresApproval:
            return true
        case .notRegistered, .notFound, .unknown:
            return false
        }
    }

    /// Whether the toggle is interactable at all. `notFound` disables it —
    /// registering from a location macOS cannot track would fail anyway.
    public var allowsToggle: Bool {
        if case .notFound = self {
            return false
        }
        return true
    }

    /// Whether the "Open Login Items Settings" shortcut button should show.
    public var showsOpenLoginItemsButton: Bool {
        self == .requiresApproval
    }

    /// Plain-language status line for the Settings card.
    public var statusDescription: String {
        switch self {
        case .notRegistered:
            return "Off — Clipboard Archive starts only when you open it."
        case .enabled:
            return "On — Clipboard Archive starts automatically when you log in."
        case .requiresApproval:
            return "Waiting for your approval in System Settings › General › Login Items. Turn on Clipboard Archive there to finish."
        case .notFound:
            return "Unavailable here — macOS can only manage login for apps in a normal location such as ~/Applications. Installed copies support this toggle."
        case let .unknown(rawValue):
            return "Unrecognized login item status (\(rawValue)). The toggle may not reflect the real state."
        }
    }
}
