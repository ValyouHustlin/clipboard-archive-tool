import AppKit
import ClipboardArchiveCore
import ClipboardArchiveUpdateRules
import Foundation

/// The app's whole part in updating: start the helper bundled beside it and
/// ask it to check. The helper does every network request; this process
/// makes none, links no updater and never hands the helper a clip.
@MainActor
enum UpdaterLauncher {
    /// The helper inside this copy, when the copy has one.
    static var helperURL: URL? {
        let url = ClipboardUpdaterLayout.helperURL(inHostApp: Bundle.main.bundleURL)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    static var configuration: ClipboardUpdateConfiguration.Outcome {
        ClipboardUpdateConfiguration.evaluate(infoDictionary: Bundle.main.infoDictionary ?? [:])
    }

    /// True when this copy was built with a helper, a feed and a key. An
    /// isolated run never counts: it must not reach for any network.
    static var isSetUp: Bool {
        !ClipboardRuntime.isIsolated && helperURL != nil && configuration.isReady
    }

    /// At launch: run the helper beside the app so scheduled checks work.
    static func startInBackgroundIfSetUp() {
        guard isSetUp, let helper = helperURL else { return }
        open(helper, arguments: [], activate: false)
    }

    /// "Check for Updates…": a running helper is told by notification, since
    /// LaunchServices does not hand arguments to an app that is already up.
    static func checkNow() {
        guard !ClipboardRuntime.isIsolated else { return }
        guard let helper = helperURL else {
            let alert = NSAlert()
            alert.messageText = "Updates are not available in this copy"
            alert.informativeText = "This copy was built without the updater. "
                + ClipboardVersionInfo.updateGuidance
            NSApp.activate(ignoringOtherApps: true)
            alert.runModal()
            return
        }
        let host = Bundle.main.bundleIdentifier ?? "app.clipboardarchive"
        let running = NSRunningApplication.runningApplications(
            withBundleIdentifier: ClipboardUpdaterLayout.helperBundleIdentifier(forHost: host)
        ).contains { $0.bundleURL?.standardizedFileURL == helper.standardizedFileURL }
        if running {
            DistributedNotificationCenter.default().postNotificationName(
                Notification.Name(ClipboardUpdaterLayout.checkNowNotification(forHost: host)),
                object: nil,
                userInfo: nil,
                deliverImmediately: true
            )
        } else {
            open(helper, arguments: ["--check-now"], activate: true)
        }
    }

    private static func open(_ helper: URL, arguments: [String], activate: Bool) {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.arguments = arguments
        configuration.activates = activate
        configuration.addsToRecentItems = false
        NSWorkspace.shared.openApplication(at: helper, configuration: configuration) { _, error in
            if error != nil {
                // Content-free: the helper failing to start is an operational
                // fact, never a reason to stop capture.
                operationalLog.record(.updaterLaunchFailed)
            }
        }
    }
}
