import AppKit
import ClipboardArchiveUpdateRules
import Foundation
import Sparkle

// The update helper. It lives at
// `Clipboard Archive.app/Contents/Helpers/Clipboard Archive Updater.app`
// and is the only process in the product that talks to a network.
//
// It never reads the clipboard, the archive or the index, and it does not
// link the code that does (ClipboardArchiveCore). What it sends is an HTTPS
// GET for the appcast and for the update file, with Sparkle's user agent
// (app name, app version, Sparkle version) and no system profile.

func fail(_ exit: ClipboardUpdaterExit, _ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    Foundation.exit(exit.rawValue)
}

guard let mode = ClipboardUpdaterMode.parse(Array(CommandLine.arguments.dropFirst())) else {
    fail(.usage, """
        usage: Clipboard Archive Updater [--check-now | --unattended [--verbose]]
          (no option)   run beside the app and check on Sparkle's schedule
          --check-now   check now and show the result in a window
          --unattended  check now, install any update without asking, then exit
                        exit 0 installed, 5 up to date, 3 updates not set up,
                        4 update refused (signature or policy), 1 failed
        """)
}

guard let hostURL = ClipboardUpdaterLayout.hostAppURL(forHelperBundle: Bundle.main.bundleURL),
      let hostBundle = Bundle(url: hostURL),
      let hostInfo = hostBundle.infoDictionary else {
    fail(.notConfigured, "The updater is not inside a Clipboard Archive app bundle, so there is nothing to update.")
}

// The helper carries the identifier of the app it was built into; a helper
// copied into some other app refuses to update it.
let expectedHost = Bundle.main.object(forInfoDictionaryKey: "ClipboardArchiveHostBundleIdentifier") as? String
guard let expectedHost, hostBundle.bundleIdentifier == expectedHost else {
    fail(.refused, "The app around this updater is not the one it was built for.")
}

let configuration = ClipboardUpdateConfiguration.evaluate(infoDictionary: hostInfo)
/// The feed this copy was built with. The library would otherwise let a
/// `SUFeedURL` in user defaults outrank it (Doctor V36).
var builtInFeedURL = ""
switch configuration {
case .ready(let feedURL):
    builtInFeedURL = feedURL.absoluteString
case .notConfigured:
    if mode == .checkNow {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.accessory)
        let alert = NSAlert()
        alert.messageText = "Updates are not set up for this copy"
        alert.informativeText = configuration.sentence
            + " Download new versions from the project's releases page."
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }
    fail(.notConfigured, configuration.sentence)
case .refused:
    fail(.refused, configuration.sentence)
}

/// Sparkle callbacks that matter to every mode: never send a profile, and
/// only ever read the feed built into the app.
class PrivacyDelegate: NSObject, SPUUpdaterDelegate {
    func feedURLString(for updater: SPUUpdater) -> String? {
        builtInFeedURL
    }

    func feedParameters(for updater: SPUUpdater, sendingSystemProfile: Bool) -> [[String: String]] {
        []
    }

    func allowedSystemProfileKeys(for updater: SPUUpdater) -> [String]? {
        []
    }
}

// MARK: - Unattended

/// Answers every question Sparkle asks with "install", and reports as it
/// goes. Modelled on Sparkle's own command-line driver.
final class UnattendedUserDriver: NSObject, SPUUserDriver {
    let verbose: Bool
    private(set) var foundVersion: String?
    private(set) var installed = false
    private var expected: UInt64 = 0
    private var received: UInt64 = 0
    private var lastPercent = -1

    init(verbose: Bool) {
        self.verbose = verbose
    }

    func say(_ line: String) {
        if verbose {
            FileHandle.standardError.write(Data((line + "\n").utf8))
        }
    }

    func show(_ request: SPUUpdatePermissionRequest, reply: @escaping (SUUpdatePermissionResponse) -> Void) {
        // An unattended run is an explicit check; it does not turn on
        // scheduled checks on the person's behalf.
        reply(SUUpdatePermissionResponse(automaticUpdateChecks: false, sendSystemProfile: false))
    }

    func showUserInitiatedUpdateCheck(cancellation: @escaping () -> Void) {
        say("Checking for updates…")
    }

    func showUpdateFound(with appcastItem: SUAppcastItem, state: SPUUserUpdateState, reply: @escaping (SPUUserUpdateChoice) -> Void) {
        if appcastItem.isInformationOnlyUpdate {
            say("Found information about \(appcastItem.displayVersionString); nothing to install.")
            reply(.dismiss)
            return
        }
        foundVersion = "\(appcastItem.displayVersionString) (\(appcastItem.versionString))"
        say("Found update \(foundVersion ?? "").")
        reply(.install)
    }

    func showUpdateReleaseNotes(with downloadData: SPUDownloadData) {}

    func showUpdateReleaseNotesFailedToDownloadWithError(_ error: Error) {}

    func showUpdateNotFoundWithError(_ error: Error, acknowledgement: @escaping () -> Void) {
        acknowledgement()
    }

    func showUpdaterError(_ error: Error, acknowledgement: @escaping () -> Void) {
        acknowledgement()
    }

    func showDownloadInitiated(cancellation: @escaping () -> Void) {
        say("Downloading…")
    }

    func showDownloadDidReceiveExpectedContentLength(_ expectedContentLength: UInt64) {
        expected = expectedContentLength
        received = 0
        say("Downloading \(expectedContentLength) bytes.")
    }

    func showDownloadDidReceiveData(ofLength length: UInt64) {
        received += length
        guard expected > 0 else { return }
        let percent = Int(Double(min(received, expected)) * 100 / Double(expected))
        if percent / 25 != lastPercent / 25 {
            lastPercent = percent
            say("Downloaded \(percent)%.")
        }
    }

    func showDownloadDidStartExtractingUpdate() {
        say("Verifying and extracting…")
    }

    func showExtractionReceivedProgress(_ progress: Double) {}

    func showReady(toInstallAndRelaunch reply: @escaping (SPUUserUpdateChoice) -> Void) {
        say("Installing…")
        reply(.install)
    }

    func showInstallingUpdate(withApplicationTerminated applicationTerminated: Bool, retryTerminatingApplication: @escaping () -> Void) {
        say(applicationTerminated ? "Replacing the app." : "Asking the running app to quit, then replacing it.")
    }

    func showUpdateInstalledAndRelaunched(_ relaunched: Bool, acknowledgement: @escaping () -> Void) {
        installed = true
        say(relaunched ? "Installed and relaunched." : "Installed.")
        acknowledgement()
    }

    func dismissUpdateInstallation() {}
}

final class UnattendedDelegate: PrivacyDelegate {
    let driver: UnattendedUserDriver

    init(driver: UnattendedUserDriver) {
        self.driver = driver
    }

    func updaterShouldPromptForPermissionToCheck(forUpdates updater: SPUUpdater) -> Bool {
        false
    }

    func updater(_ updater: SPUUpdater, shouldDownloadReleaseNotesForUpdate updateItem: SUAppcastItem) -> Bool {
        false
    }

    func updater(_ updater: SPUUpdater, willScheduleUpdateCheckAfterDelay delay: TimeInterval) {}

    func updater(_ updater: SPUUpdater, didFinishUpdateCycleFor updateCheck: SPUUpdateCheck, error: Error?) {
        guard let error = error as NSError? else {
            let outcome = ClipboardUpdaterExit.forCleanFinish(found: driver.foundVersion != nil, installed: driver.installed)
            switch outcome {
            case .installed:
                print("installed: \(driver.foundVersion ?? "the update")")
            case .upToDate:
                print("up to date")
            default:
                print("failed: found \(driver.foundVersion ?? "an update") but it was not installed")
            }
            exit(outcome.rawValue)
        }
        var chain: [NSError] = [error]
        while chain.count < 8, let next = chain.last?.userInfo[NSUnderlyingErrorKey] as? NSError {
            chain.append(next)
        }
        let outcome = ClipboardUpdaterExit.classify(
            errorChain: chain.map { (fromUpdater: $0.domain == SUSparkleErrorDomain, code: $0.code) }
        )
        if outcome == .upToDate {
            print("up to date")
            exit(outcome.rawValue)
        }
        let reason = chain.map { "\($0.localizedDescription) (\($0.domain) \($0.code))" }.joined(separator: "; ")
        print("\(outcome == .refused ? "refused" : "failed"): \(reason)")
        exit(outcome.rawValue)
    }
}

// MARK: - Beside the app

/// Runs for as long as the app does: Sparkle's schedule and windows, plus a
/// "check now" the app can ask for without linking any of this.
final class BackgroundDelegate: PrivacyDelegate {
    var updater: SPUUpdater?
    let hostURL: URL

    init(hostURL: URL, hostIdentifier: String) {
        self.hostURL = hostURL
        super.init()
        DistributedNotificationCenter.default().addObserver(
            self,
            selector: #selector(checkNow),
            name: Notification.Name(ClipboardUpdaterLayout.checkNowNotification(forHost: hostIdentifier)),
            object: nil
        )
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(applicationTerminated(_:)),
            name: NSWorkspace.didTerminateApplicationNotification,
            object: nil
        )
    }

    @objc func checkNow() {
        guard let updater, updater.canCheckForUpdates else { return }
        NSApp.activate(ignoringOtherApps: true)
        updater.checkForUpdates()
    }

    /// The installer relaunches the new app, and the new app starts the new
    /// helper. This one, from the replaced bundle, steps aside.
    func updaterWillRelaunchApplication(_ updater: SPUUpdater) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            NSApp.terminate(nil)
        }
    }

    /// Leave with the app, unless an update is in flight: then the install
    /// is what is quitting the app, and the helper has to see it through.
    @objc func applicationTerminated(_ notification: Notification) {
        guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
              app.bundleURL?.standardizedFileURL == hostURL.standardizedFileURL else {
            return
        }
        if updater?.sessionInProgress != true {
            NSApp.terminate(nil)
        }
    }
}

_ = NSApplication.shared
NSApp.setActivationPolicy(.accessory)

switch mode {
case .unattended(let verbose):
    let driver = UnattendedUserDriver(verbose: verbose)
    let delegate = UnattendedDelegate(driver: driver)
    let updater = SPUUpdater(hostBundle: hostBundle, applicationBundle: hostBundle, userDriver: driver, delegate: delegate)
    do {
        try updater.start()
    } catch {
        fail(.failed, "failed: the updater could not start: \(error.localizedDescription)")
    }
    updater.checkForUpdates()
    withExtendedLifetime((driver, delegate, updater)) {
        NSApp.run()
    }
case .background, .checkNow:
    let delegate = BackgroundDelegate(hostURL: hostURL, hostIdentifier: expectedHost)
    let driver = SPUStandardUserDriver(hostBundle: hostBundle, delegate: nil)
    let updater = SPUUpdater(hostBundle: hostBundle, applicationBundle: hostBundle, userDriver: driver, delegate: delegate)
    delegate.updater = updater
    do {
        try updater.start()
    } catch {
        fail(.failed, "failed: the updater could not start: \(error.localizedDescription)")
    }
    if mode == .checkNow {
        delegate.checkNow()
    }
    withExtendedLifetime((driver, delegate, updater)) {
        NSApp.run()
    }
}
