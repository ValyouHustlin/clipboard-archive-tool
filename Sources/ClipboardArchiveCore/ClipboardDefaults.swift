import Foundation

public enum ClipboardDefaults {
    public static let appSupportFolderName = "ClipboardArchive"
    public static let archiveEnvironmentKey = "CLIPBOARD_ARCHIVE_ARCHIVE_ROOT"
    public static let indexEnvironmentKey = "CLIPBOARD_ARCHIVE_INDEX_PATH"

    public static func archiveRoot(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        if let path = environment[archiveEnvironmentKey], !path.isEmpty {
            return URL(fileURLWithPath: path)
        }
        return applicationSupportRoot()
            .appendingPathComponent("Archive", isDirectory: true)
            .appendingPathComponent("clipboard-history", isDirectory: true)
    }

    public static func indexURL(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        if let path = environment[indexEnvironmentKey], !path.isEmpty {
            return URL(fileURLWithPath: path)
        }
        return applicationSupportRoot()
            .appendingPathComponent("Indexes", isDirectory: true)
            .appendingPathComponent("clipboard-search.sqlite")
    }

    public static func settingsURL() -> URL {
        applicationSupportRoot().appendingPathComponent("settings.json")
    }

    public static func lockURL() -> URL {
        applicationSupportRoot().appendingPathComponent("ClipboardArchive.lock")
    }

    public static func applicationSupportRoot() -> URL {
        FileManager.default
            .homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/\(appSupportFolderName)", isDirectory: true)
    }
}
