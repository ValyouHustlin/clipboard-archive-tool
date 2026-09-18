import CryptoKit
import Foundation

/// Scratch operation uses file-backed preferences and a named pasteboard. No
/// CFPreferences domain is created, including during property initialization.
public enum ClipboardRuntime {
    public static var isIsolated: Bool {
        !(ProcessInfo.processInfo.environment[ClipboardDefaults.applicationSupportEnvironmentKey] ?? "").isEmpty
    }

    public static func isScratchPath(_ url: URL) -> Bool {
        let path = url.resolvingSymlinksInPath().path
        return path.hasPrefix("/private/tmp/") || path.hasPrefix("/tmp/")
    }

    /// Set to `general` by a harness that deliberately wants the REAL
    /// pasteboard inside an otherwise isolated run.
    public static let pasteboardEnvironmentKey = "CLIPBOARD_ARCHIVE_PASTEBOARD"

    /// The named pasteboard an isolated run should use, or nil for
    /// `NSPasteboard.general`.
    ///
    /// The opt-out exists because inferring the pasteboard swap from a PATH
    /// override silently broke the one in-repo harness that drives the app end
    /// to end: `scripts/stress-menu-bar-app.sh` sets the support root for store
    /// isolation and then copies through `pbcopy`, so the app sat watching a
    /// private board while the test typed into the general one and every
    /// assertion failed. A harness that means "isolate my stores, but watch the
    /// real clipboard" now has a way to say exactly that, instead of the choice
    /// being welded to an unrelated variable.
    public static var pasteboardName: String? {
        if let choice = ProcessInfo.processInfo.environment[pasteboardEnvironmentKey],
           choice.lowercased() == "general" {
            return nil
        }
        guard isIsolated else { return nil }
        let root = ClipboardDefaults.applicationSupportRoot().resolvingSymlinksInPath().path
        let digest = SHA256.hash(data: Data(root.utf8)).map { String(format: "%02x", $0) }.joined()
        return "app.clipboardarchive.scratch." + digest
    }

    /// Only scratch runs consult this file. Replacing its epoch-seconds value
    /// changes calendar time without changing timer/deadline monotonic time.
    public static var now: Date {
        guard isIsolated,
              let text = try? String(contentsOf: ClipboardDefaults.applicationSupportRoot()
                .appendingPathComponent("clock.txt"), encoding: .utf8),
              let seconds = Double(text.trimmingCharacters(in: .whitespacesAndNewlines)),
              seconds.isFinite, abs(seconds) < 100_000_000_000 else { return Date() }
        return Date(timeIntervalSince1970: seconds)
    }
}

public final class ClipboardPreferences {
    private let fileURL: URL?
    public init(environment: [String: String] = ProcessInfo.processInfo.environment) {
        if let path = environment[ClipboardDefaults.applicationSupportEnvironmentKey], !path.isEmpty {
            fileURL = URL(fileURLWithPath: path).appendingPathComponent("preferences.json")
        } else { fileURL = nil }
    }
    public func bool(forKey key: String) -> Bool {
        guard let fileURL else { return UserDefaults.standard.bool(forKey: key) }
        guard let data = try? Data(contentsOf: fileURL),
              let values = try? JSONDecoder().decode([String: Bool].self, from: data) else { return false }
        return values[key] ?? false
    }
    public func set(_ value: Bool, forKey key: String) {
        guard let fileURL else { UserDefaults.standard.set(value, forKey: key); return }
        var values = (try? Data(contentsOf: fileURL)).flatMap {
            try? JSONDecoder().decode([String: Bool].self, from: $0)
        } ?? [:]
        values[key] = value
        do {
            try ClipboardPrivateFileSystem.createDirectory(fileURL.deletingLastPathComponent(), archiveRoot: fileURL.deletingLastPathComponent())
            try JSONEncoder().encode(values).writeClipboardAtomically(to: fileURL)
            try ClipboardPrivateFileSystem.secureFile(fileURL)
        } catch {
            // Preferences never fall through to a host domain on failure.
            FileHandle.standardError.write(Data("Scratch preferences could not be saved (\((error as NSError).domain):\((error as NSError).code)).\n".utf8))
        }
    }
}

/// A run that pinned some stores into scratch but left the application-support
/// root on the user's real one.
///
/// It exists because `ClipboardRuntime.isIsolated` keys on the support root
/// ALONE. Set the archive and the index into /tmp, forget that one variable,
/// and the run reads and writes scratch stores while its preferences, its
/// pasteboard, its clock seam and its log directory all stay production — a
/// half-isolated run that looks isolated from the outside. A certification
/// cycle graded this build twice in that state and reported the results as
/// scratch measurements.
public struct ClipboardIsolationBreach: Sendable, Equatable {
    /// Store variables whose value names a scratch path.
    public var scratchKeys: [String]
    /// The surfaces that stay on the user's real data regardless.
    public var productionSurfaces: [String]

    /// One sentence a person can act on, naming the variable to set.
    public var sentence: String {
        "Stores are pinned into scratch (\(scratchKeys.joined(separator: ", "))) but "
        + "\(ClipboardDefaults.applicationSupportEnvironmentKey) is not set, so "
        + productionSurfaces.dropLast().joined(separator: ", ")
        + " and \(productionSurfaces.last ?? "") still resolve to the real ones. "
        + "Set that variable too, or unset the others."
    }
}

extension ClipboardRuntime {
    /// The variables that pin a store somewhere other than the per-user default.
    public static let storeEnvironmentKeys = [
        ClipboardDefaults.archiveEnvironmentKey,
        ClipboardDefaults.indexEnvironmentKey,
        "CLIPBOARD_ARCHIVE_LAUNCH_AGENT_PLIST"
    ]

    /// Non-nil when a run pinned stores into scratch without isolating the
    /// support root.
    ///
    /// A launch agent that pins the archive and index to their REAL paths is
    /// not a breach and must not warn — that is ordinary production
    /// configuration, and it is why this keys on the path being scratch rather
    /// than on the variable merely being present.
    public static func isolationBreach(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> ClipboardIsolationBreach? {
        // Read the support root from the PASSED environment, not from
        // `isIsolated`, which always reads the process. A check that cannot be
        // driven from a test is the shape of defect this one exists to catch.
        let supportRoot = environment[ClipboardDefaults.applicationSupportEnvironmentKey] ?? ""
        guard supportRoot.isEmpty else { return nil }
        let scratch = storeEnvironmentKeys.filter { key in
            guard let value = environment[key], !value.isEmpty else { return false }
            return isScratchPath(URL(fileURLWithPath: value))
        }
        guard !scratch.isEmpty else { return nil }
        return ClipboardIsolationBreach(
            scratchKeys: scratch,
            productionSurfaces: ["preferences", "the pasteboard", "the clock seam", "the log directory"]
        )
    }
}
