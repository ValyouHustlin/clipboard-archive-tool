import Foundation

public enum ClipboardDefaults {
    public static let appSupportFolderName = "ClipboardArchive"
    public static let archiveEnvironmentKey = "CLIPBOARD_ARCHIVE_ARCHIVE_ROOT"
    public static let indexEnvironmentKey = "CLIPBOARD_ARCHIVE_INDEX_PATH"
    public static let applicationSupportEnvironmentKey = "CLIPBOARD_ARCHIVE_APPLICATION_SUPPORT_ROOT"
    public static let isolatedUserDefaultsSuiteName = "app.clipboardarchive.isolated-development"

    public static func archiveRoot(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        if let path = environment[archiveEnvironmentKey], !path.isEmpty {
            return URL(fileURLWithPath: path)
        }
        return applicationSupportRoot(environment: environment)
            .appendingPathComponent("Archive", isDirectory: true)
            .appendingPathComponent("clipboard-history", isDirectory: true)
    }

    public static func indexURL(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        if let path = environment[indexEnvironmentKey], !path.isEmpty {
            return URL(fileURLWithPath: path)
        }
        return applicationSupportRoot(environment: environment)
            .appendingPathComponent("Indexes", isDirectory: true)
            .appendingPathComponent("clipboard-search.sqlite")
    }

    public static func settingsURL(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        applicationSupportRoot(environment: environment).appendingPathComponent("settings.json")
    }

    public static func lockURL(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        applicationSupportRoot(environment: environment).appendingPathComponent("ClipboardArchive.lock")
    }

    /// Where the operational log lives. It follows the application-support
    /// root when one is set, so an isolated run logs inside its own scratch
    /// tree; otherwise it is the per-user Logs folder the launch agent
    /// already writes its stdout and stderr into, where Console shows it.
    public static func logDirectory(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        if let path = environment[applicationSupportEnvironmentKey], !path.isEmpty {
            return URL(fileURLWithPath: path, isDirectory: true)
                .appendingPathComponent("Logs", isDirectory: true)
        }
        return FileManager.default
            .homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/\(appSupportFolderName)", isDirectory: true)
    }

    public static func applicationSupportRoot(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL {
        if let path = environment[applicationSupportEnvironmentKey], !path.isEmpty {
            return URL(fileURLWithPath: path, isDirectory: true)
        }
        return FileManager.default
            .homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/\(appSupportFolderName)", isDirectory: true)
    }

    public static func userDefaultsSuiteName(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> String? {
        guard let path = environment[applicationSupportEnvironmentKey], !path.isEmpty else {
            return nil
        }
        return isolatedUserDefaultsSuiteName
    }
}
