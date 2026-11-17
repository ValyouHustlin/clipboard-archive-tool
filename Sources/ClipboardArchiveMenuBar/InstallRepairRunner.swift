import AppKit
import ClipboardArchiveCore
import Darwin
import Foundation

/// Carries out the two `ClipboardInstallRepair` decisions at launch. Every
/// failure here falls back to what the app did before: the second copy
/// exits, and the login item is left as it is.
@MainActor
enum InstallRepairRunner {
    private static let launchAgentEnvironmentKey = "CLIPBOARD_ARCHIVE_LAUNCH_AGENT_PLIST"

    static func describe(bundleAt path: String) -> ClipboardInstallRepair.Copy? {
        guard FileManager.default.fileExists(atPath: path),
              let bundle = Bundle(path: path) else {
            return nil
        }
        return ClipboardInstallRepair.Copy(
            path: path,
            bundleIdentifier: bundle.bundleIdentifier,
            build: (bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String).flatMap(Int.init)
        )
    }

    static var own: ClipboardInstallRepair.Copy {
        ClipboardInstallRepair.Copy(
            path: Bundle.main.bundlePath,
            bundleIdentifier: Bundle.main.bundleIdentifier,
            build: (Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String).flatMap(Int.init)
        )
    }

    /// Where people install the app. An isolated run counts its own scratch
    /// folder, so the behaviour can be exercised without touching a real
    /// install.
    static var installFolders: [String] {
        var folders = [
            "/Applications",
            FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications").path
        ]
        let ownURL = URL(fileURLWithPath: Bundle.main.bundlePath)
        if ClipboardRuntime.isIsolated, ClipboardRuntime.isScratchPath(ownURL) {
            folders.append(ownURL.deletingLastPathComponent().path)
        }
        return folders
    }

    /// Asks an older copy holding the single-instance lock to quit, and
    /// waits for it to go. Returns true when it has gone and the lock is
    /// worth asking for again.
    static func takeOver(fromPID pid: Int) -> Bool {
        guard pid > 0, pid != Int(getpid()),
              let running = NSRunningApplication(processIdentifier: pid_t(pid)),
              let holderPath = running.bundleURL?.path else {
            return false
        }
        guard ClipboardInstallRepair.shouldTakeOver(
            own: own,
            holder: describe(bundleAt: holderPath),
            installFolders: installFolders
        ) else {
            return false
        }

        // A normal quit first, so the older copy writes its stop row and
        // releases the archive cleanly; then the same signal the installer
        // sends. Never a forced kill: a copy that will not stop keeps the
        // lock and this one exits, as before.
        _ = running.terminate()
        for attempt in 0..<50 {
            if kill(pid_t(pid), 0) != 0 {
                return true
            }
            if attempt == 25 {
                kill(pid_t(pid), SIGTERM)
            }
            Thread.sleep(forTimeInterval: 0.1)
        }
        return kill(pid_t(pid), 0) != 0
    }

    /// Points the login item at this copy when it still starts an older or
    /// missing one. Returns the path it used to name, or nil when nothing
    /// was changed.
    @discardableResult
    static func repairLoginItemIfNeeded() -> String? {
        let environment = ProcessInfo.processInfo.environment
        let plistURL: URL
        if let override = environment[launchAgentEnvironmentKey], !override.isEmpty {
            plistURL = URL(fileURLWithPath: override)
        } else if ClipboardRuntime.isIsolated {
            // An isolated run with no login item of its own must never
            // reach the real one.
            return nil
        } else {
            plistURL = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/LaunchAgents/app.clipboardarchive.plist")
        }
        guard let existing = try? Data(contentsOf: plistURL),
              let repair = ClipboardInstallRepair.repairedLaunchAgent(
                  plist: existing,
                  own: own,
                  installFolders: installFolders,
                  describe: describe(bundleAt:)
              ) else {
            return nil
        }
        let permissions = (try? FileManager.default.attributesOfItem(atPath: plistURL.path))?[.posixPermissions]
        do {
            try repair.data.writeClipboardAtomically(to: plistURL)
            if let permissions {
                try? FileManager.default.setAttributes([.posixPermissions: permissions], ofItemAtPath: plistURL.path)
            }
            return repair.replacedTarget
        } catch {
            return nil
        }
    }
}
