import Darwin
import Foundation

/// Where a resolved store path came from.
public enum ClipboardStoreOrigin: String, Codable, Sendable {
    /// An explicit `--archive-root` / `--index-path` argument.
    case flag
    /// `CLIPBOARD_ARCHIVE_ARCHIVE_ROOT` / `CLIPBOARD_ARCHIVE_INDEX_PATH`.
    case env
    /// The pointer file the app publishes at launch.
    case pointer
    /// The per-user Application Support layout.
    case `default`
}

/// What happened to the pointer file during a resolution. It describes the
/// FILE, so it reads the same however the caller's flags and environment
/// happened to override it; the per-path `origin` says which source won.
///
/// Priority when more than one applies: `unreadable`, then
/// `ignoredDefaultOrigin`, then `ignoredMissingPath`, then `used`.
public enum ClipboardStorePointerStatus: String, Codable, Sendable {
    /// No pointer file exists.
    case absent
    /// Every entry names an env/flag origin and a path that exists.
    case used
    /// At least one entry was published from a non-env/flag origin, so it
    /// cannot be trusted to name the store the app is really using.
    case ignoredDefaultOrigin = "ignored-default-origin"
    /// At least one entry names a path that is no longer there.
    case ignoredMissingPath = "ignored-missing-path"
    /// The file exists but is not a pointer document this build understands.
    case unreadable
}

/// Explicit caller overrides — the highest-precedence source.
public struct ClipboardStoreOverrides: Sendable, Equatable {
    public var archiveRoot: URL?
    public var indexPath: URL?

    public init(archiveRoot: URL? = nil, indexPath: URL? = nil) {
        self.archiveRoot = archiveRoot
        self.indexPath = indexPath
    }
}

/// One resolution: every store path a surface needs, plus where each of the
/// two variable ones came from.
public struct ClipboardStoreResolution: Sendable, Equatable {
    public var archiveRoot: URL
    public var archiveOrigin: ClipboardStoreOrigin
    public var indexPath: URL
    public var indexOrigin: ClipboardStoreOrigin
    public var pointerStatus: ClipboardStorePointerStatus
    public var applicationSupportRoot: URL
    public var settingsURL: URL
    public var lockURL: URL
    public var pointerURL: URL
    /// Where operational rows go. Resolved here so the app, the CLI and an
    /// isolated test all reach the same decision from the same inputs.
    public var logDirectory: URL
}

/// The ONE place the app and the CLI decide which archive and which index
/// they are talking about.
///
/// Precedence, applied to the archive and the index INDEPENDENTLY:
/// explicit override → environment variable → pointer file → the per-user
/// Application Support default. The pointer file is what lets a terminal
/// with no environment read the same stores as the app launchd started;
/// without it the two silently disagree.
///
/// The pointer is deliberately weak. It is only followed for an entry the
/// app published from an environment variable or an explicit flag, and only
/// while that path still exists — so one environment-less hand launch
/// cannot redirect every later command, and a store that has moved away
/// falls back to the default instead of reading nothing.
public enum ClipboardStoreLocator {
    public static let pointerFileName = "stores.json"
    public static let pointerSchemaVersion = 1

    // MARK: - Resolving

    public static func resolve(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        overrides: ClipboardStoreOverrides = ClipboardStoreOverrides()
    ) -> ClipboardStoreResolution {
        let applicationSupportRoot = ClipboardDefaults.applicationSupportRoot(environment: environment)
        let pointerURL = applicationSupportRoot.appendingPathComponent(pointerFileName)
        let load = loadPointer(at: pointerURL)

        let archive = resolveEntry(
            override: overrides.archiveRoot,
            environmentValue: environment[ClipboardDefaults.archiveEnvironmentKey],
            pointerPath: load.document?.archiveRoot,
            pointerOrigin: load.document?.archiveOrigin,
            pathIsUsable: directoryExists,
            fallback: { ClipboardDefaults.archiveRoot(environment: environment) }
        )
        let index = resolveEntry(
            override: overrides.indexPath,
            environmentValue: environment[ClipboardDefaults.indexEnvironmentKey],
            pointerPath: load.document?.indexPath,
            pointerOrigin: load.document?.indexOrigin,
            // The index file itself is created on first write, so the
            // parent directory is the honest existence test.
            pathIsUsable: { directoryExists($0.deletingLastPathComponent()) },
            fallback: { ClipboardDefaults.indexURL(environment: environment) }
        )

        return ClipboardStoreResolution(
            archiveRoot: archive.url,
            archiveOrigin: archive.origin,
            indexPath: index.url,
            indexOrigin: index.origin,
            pointerStatus: pointerStatus(
                load: load,
                entries: [archive.pointerEntry, index.pointerEntry]
            ),
            applicationSupportRoot: applicationSupportRoot,
            settingsURL: ClipboardDefaults.settingsURL(environment: environment),
            lockURL: ClipboardDefaults.lockURL(environment: environment),
            pointerURL: pointerURL,
            logDirectory: ClipboardDefaults.logDirectory(environment: environment)
        )
    }

    // MARK: - Publishing

    /// Writes the pointer file naming only the paths this process resolved
    /// from an environment variable or an explicit flag. Entries resolved
    /// any other way keep whatever the existing pointer said, and a
    /// resolution with nothing publishable writes nothing at all — an
    /// environment-less launch must never redirect the next command.
    ///
    /// Returns true when a pointer was written. Callers treat this as best
    /// effort: a failure to publish must never block a launch.
    @discardableResult
    public static func publishPointer(
        for resolution: ClipboardStoreResolution,
        writtenBy: String,
        now: Date = ClipboardRuntime.now
    ) throws -> Bool {
        let archivePublishable = isPublishable(resolution.archiveOrigin)
        let indexPublishable = isPublishable(resolution.indexOrigin)
        guard archivePublishable || indexPublishable else {
            return false
        }

        let existing = loadPointer(at: resolution.pointerURL).document
        var document = ClipboardStorePointerDocument(
            writtenBy: writtenBy,
            updatedAt: pointerTimestamp(now)
        )
        if archivePublishable {
            document.archiveRoot = resolution.archiveRoot.path
            document.archiveOrigin = resolution.archiveOrigin.rawValue
        } else {
            document.archiveRoot = existing?.archiveRoot
            document.archiveOrigin = existing?.archiveOrigin
        }
        if indexPublishable {
            document.indexPath = resolution.indexPath.path
            document.indexOrigin = resolution.indexOrigin.rawValue
        } else {
            document.indexPath = existing?.indexPath
            document.indexOrigin = existing?.indexOrigin
        }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        try writeAtomically(try encoder.encode(document), to: resolution.pointerURL)
        return true
    }

    // MARK: - Alternate index

    /// A legacy-default index file that exists but is NOT the resolved
    /// index — the footgun that let a terminal read a different database
    /// from the app. Reported so it is visible instead of silent; nothing
    /// here writes, moves or rebuilds it.
    public struct AlternateIndexReport: Sendable, Equatable {
        public var path: String
        public var bytes: Int64
        public var rowCount: Int?
        public var userVersion: Int?
    }

    public static func alternateIndexReport(
        for resolution: ClipboardStoreResolution,
        sqliteExecutableURL: URL = URL(fileURLWithPath: "/usr/bin/sqlite3")
    ) -> AlternateIndexReport? {
        let legacy = resolution.applicationSupportRoot
            .appendingPathComponent("Indexes", isDirectory: true)
            .appendingPathComponent("clipboard-search.sqlite")
        guard legacy.standardizedFileURL.path != resolution.indexPath.standardizedFileURL.path else {
            return nil
        }
        var info = stat()
        guard lstat(legacy.path, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else {
            return nil
        }

        let rows = readOnlyScalar(
            sql: "SELECT COUNT(*) AS value FROM clipboard_meta;",
            database: legacy,
            sqliteExecutableURL: sqliteExecutableURL
        )
        let userVersion = readOnlyScalar(
            sql: "SELECT user_version AS value FROM pragma_user_version;",
            database: legacy,
            sqliteExecutableURL: sqliteExecutableURL
        )
        return AlternateIndexReport(
            path: legacy.path,
            bytes: Int64(info.st_size),
            rowCount: rows,
            userVersion: userVersion
        )
    }

    // MARK: - Pointer document

    struct ClipboardStorePointerDocument: Codable, Equatable {
        var schema: Int = ClipboardStoreLocator.pointerSchemaVersion
        var archiveRoot: String?
        var archiveOrigin: String?
        var indexPath: String?
        var indexOrigin: String?
        var writtenBy: String
        var updatedAt: String
    }

    private struct PointerLoad {
        var document: ClipboardStorePointerDocument?
        var exists: Bool
        var unreadable: Bool
    }

    private enum PointerEntryDisposition {
        /// The pointer named this path and it was used.
        case used
        /// The pointer has no entry for this path.
        case missingEntry
        case rejectedOrigin
        case rejectedMissingPath
        /// The entry was fine, but a flag or the environment outranked it.
        case outranked
    }

    // MARK: - Internals

    /// Built per call, like the usage log's: `ISO8601DateFormatter` is not
    /// Sendable, and a pointer is written once per launch.
    private static func pointerTimestamp(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }

    private static func isPublishable(_ origin: ClipboardStoreOrigin) -> Bool {
        origin == .env || origin == .flag
    }

    private static func resolveEntry(
        override: URL?,
        environmentValue: String?,
        pointerPath: String?,
        pointerOrigin: String?,
        pathIsUsable: (URL) -> Bool,
        fallback: () -> URL
    ) -> (url: URL, origin: ClipboardStoreOrigin, pointerEntry: PointerEntryDisposition) {
        let entry = gradePointerEntry(
            path: pointerPath,
            origin: pointerOrigin,
            pathIsUsable: pathIsUsable
        )

        if let override {
            return (override, .flag, entry == .used ? .outranked : entry)
        }
        if let environmentValue, !environmentValue.isEmpty {
            return (URL(fileURLWithPath: environmentValue), .env, entry == .used ? .outranked : entry)
        }
        if entry == .used, let pointerPath {
            return (URL(fileURLWithPath: pointerPath), .pointer, .used)
        }
        return (fallback(), .default, entry)
    }

    private static func gradePointerEntry(
        path: String?,
        origin: String?,
        pathIsUsable: (URL) -> Bool
    ) -> PointerEntryDisposition {
        guard let path, !path.isEmpty else {
            // No entry at all is not a fault: the app publishes only the
            // paths it resolved from an environment variable or a flag.
            return origin == nil ? .missingEntry : .rejectedOrigin
        }
        guard let origin, let parsed = ClipboardStoreOrigin(rawValue: origin), isPublishable(parsed) else {
            return .rejectedOrigin
        }
        return pathIsUsable(URL(fileURLWithPath: path)) ? .used : .rejectedMissingPath
    }

    private static func pointerStatus(
        load: PointerLoad,
        entries: [PointerEntryDisposition]
    ) -> ClipboardStorePointerStatus {
        guard load.exists else { return .absent }
        guard !load.unreadable else { return .unreadable }
        if entries.contains(.rejectedOrigin) { return .ignoredDefaultOrigin }
        if entries.contains(.rejectedMissingPath) { return .ignoredMissingPath }
        if entries.contains(where: { $0 == .used || $0 == .outranked }) { return .used }
        // A document with no usable entry at all names no store.
        return .ignoredDefaultOrigin
    }

    private static func loadPointer(at url: URL) -> PointerLoad {
        var info = stat()
        guard lstat(url.path, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else {
            return PointerLoad(document: nil, exists: false, unreadable: false)
        }
        guard let data = try? Data(contentsOf: url),
              let document = try? JSONDecoder().decode(ClipboardStorePointerDocument.self, from: data),
              document.schema == pointerSchemaVersion else {
            return PointerLoad(document: nil, exists: true, unreadable: true)
        }
        return PointerLoad(document: document, exists: true, unreadable: false)
    }

    private static func directoryExists(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
            return false
        }
        return isDirectory.boolValue
    }

    /// Temp file beside the target, 0600 from creation, then rename — a
    /// reader never sees a half-written pointer, and the bytes are never
    /// world-readable even briefly. The directory is tightened to 0700 the
    /// same way the lock and usage-log directories are.
    private static func writeAtomically(_ data: Data, to url: URL) throws {
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        // Tighten the directory through its own descriptor, opened without
        // following links: a path-based chmod would follow a symlinked
        // support root and change the mode of whatever it points at.
        let directoryFD = open(directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        if directoryFD >= 0 {
            _ = fchmod(directoryFD, 0o700)
            close(directoryFD)
        }

        let temporary = directory.appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString)")
        let descriptor = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else {
            throw ClipboardStoreLocatorError.pointerWriteFailed(errno)
        }
        var written = false
        defer {
            close(descriptor)
            if !written {
                try? FileManager.default.removeItem(at: temporary)
            }
        }
        try data.withUnsafeBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                let count = write(descriptor, buffer.baseAddress!.advanced(by: offset), buffer.count - offset)
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else {
                    throw ClipboardStoreLocatorError.pointerWriteFailed(errno)
                }
                offset += count
            }
        }
        guard fchmod(descriptor, 0o600) == 0 else {
            throw ClipboardStoreLocatorError.pointerWriteFailed(errno)
        }
        // Flush before the rename so a crash cannot publish a pointer whose
        // name is in place but whose bytes are not.
        guard fsync(descriptor) == 0 else {
            throw ClipboardStoreLocatorError.pointerWriteFailed(errno)
        }
        guard rename(temporary.path, url.path) == 0 else {
            throw ClipboardStoreLocatorError.pointerWriteFailed(errno)
        }
        written = true
    }

    /// One scalar from a database this process must not modify: `-readonly`
    /// so a missing or corrupt file cannot be created or journalled here.
    private static func readOnlyScalar(
        sql: String,
        database: URL,
        sqliteExecutableURL: URL
    ) -> Int? {
        let process = Process()
        process.executableURL = sqliteExecutableURL
        process.arguments = ["-readonly", "-json", "-batch", database.path]
        let input = Pipe()
        let output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }
        do {
            try input.fileHandleForWriting.write(contentsOf: Data(sql.utf8))
            try input.fileHandleForWriting.close()
        } catch {
            process.terminate()
            return nil
        }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0,
              let rows = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            return nil
        }
        return rows.first?["value"] as? Int
    }
}

public enum ClipboardStoreLocatorError: Error, CustomStringConvertible {
    case pointerWriteFailed(Int32)

    public var description: String {
        switch self {
        case let .pointerWriteFailed(code):
            return "could not write the store pointer (errno \(code))"
        }
    }
}
