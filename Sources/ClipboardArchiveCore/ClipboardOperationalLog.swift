import Darwin
import Foundation

/// Resident memory of this process, in bytes, or 0 when the kernel will not
/// say. Used only as a heartbeat field: a number a person can trend, with no
/// bearing on behaviour.
public enum ClipboardProcessMetrics {
    public static func residentSetBytes() -> Int {
        var usage = rusage_info_current()
        let status = withUnsafeMutablePointer(to: &usage) { pointer in
            pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { rebound in
                proc_pid_rusage(getpid(), RUSAGE_INFO_CURRENT, rebound)
            }
        }
        guard status == 0 else {
            return 0
        }
        return Int(usage.ri_resident_size)
    }
}

/// What the app and the CLI were DOING, as a content-free operational
/// record: launches and stops, capture failures by class, refused second
/// instances, settings fallbacks, index rebuilds, prunes, and a periodic
/// heartbeat that proves the process is alive and still polling.
///
/// Content-free BY CONSTRUCTION, the same discipline as the usage log: the
/// API accepts no free-form string, no `Error`, no path, no identifier. The
/// only textual fields are closed enums defined here, so a clipboard body, a
/// file name or an error message cannot enter a row even by mistake.
///
/// Every row carries every field. Unused numbers are zero rather than
/// absent, so a reader (and a schema test) can rely on one fixed key set.
///
/// The heartbeat is the reason this log exists. A launch path that silently
/// stops running is invisible to every event-present record — only a row
/// that should be there and is not can catch it.
public struct ClipboardOperationalLog: Sendable {
    /// Severity, for the `--errors` filter and a human scanning the file.
    public enum Level: String, Codable, Sendable {
        case info, warn, error
    }

    /// Which part of the system the row is about.
    public enum Component: String, Codable, Sendable {
        case app, capture, archive, index, settings, retention, launch, cli
    }

    /// The closed set of things that can be recorded. A new kind of row is a
    /// code added here with a caller — never a string passed in.
    public enum Code: String, Codable, Sendable {
        /// Launch, after the single-instance lock was taken.
        case appStart = "app_start"
        case appStop = "app_stop"
        /// The dead-man row: polls and captures since the previous
        /// heartbeat, resident bytes now, and how long ago the last
        /// successful capture of this run was (`durationMs`, which is 0
        /// both for "never captured" and for "captured just now").
        case heartbeat
        /// Another instance already held the lock; this process exited.
        /// `count` carries the holder's pid, or 0 when it could not be read.
        case secondInstanceRefused = "second_instance_refused"
        /// Settings could not be read and defaults were substituted — a
        /// data-affecting event, because defaults are not the user's
        /// retention choice.
        case settingsFallback = "settings_fallback"
        /// Settings could not be read and the last known-good copy was used
        /// instead of defaults — the user's own choices survived.
        case settingsLastGoodUsed = "settings_last_good_used"
        /// A capture could not be archived, by reason class (`errno`).
        case captureFailed = "capture_failed"
        /// A capture succeeded after a failure: the archive is writable again.
        case captureRecovered = "capture_recovered"
        /// The index file named by this process is gone; the searchable
        /// copy is being rebuilt from the archive.
        case indexMissingDetected = "index_missing_detected"
        /// The index file failed its integrity check or carries a schema
        /// this build does not use; same recovery, a rebuild.
        case indexCorruptDetected = "index_corrupt_detected"
        case indexUpsertFailed = "index_upsert_failed"
        case indexRebuildStarted = "index_rebuild_started"
        case indexRebuildFinished = "index_rebuild_finished"
        case indexRebuildFailed = "index_rebuild_failed"
        /// A day file's append could not complete; `errno` carries the
        /// reason class. No row was written and no partial row survives.
        case archiveAppendFailed = "archive_append_failed"
        /// A day file whose last row lost its terminator was closed with one
        /// newline before the next row was appended, so the torn fragment
        /// costs exactly one line instead of two.
        case archiveTailRepaired = "archive_tail_repaired"
        case retentionPruned = "retention_pruned"
        case expirySwept = "expiry_swept"
        case pointerPublished = "pointer_published"
        case pointerPublishFailed = "pointer_publish_failed"
        /// One row per CLI invocation: `verb` names the command and
        /// `count` carries its exit code (0 on success).
        case cliCommand = "cli_command"

        /// The component a code always belongs to — derived, never passed,
        /// so the same code can never be filed under two components.
        public var component: Component {
            switch self {
            case .appStart, .appStop, .heartbeat:
                return .app
            case .secondInstanceRefused, .pointerPublished, .pointerPublishFailed:
                return .launch
            case .settingsFallback, .settingsLastGoodUsed:
                return .settings
            case .captureFailed, .captureRecovered:
                return .capture
            case .indexUpsertFailed, .indexRebuildStarted, .indexRebuildFinished, .indexRebuildFailed,
                 .indexMissingDetected, .indexCorruptDetected:
                return .index
            case .archiveAppendFailed, .archiveTailRepaired:
                return .archive
            case .retentionPruned, .expirySwept:
                return .retention
            case .cliCommand:
                return .cli
            }
        }

        /// The severity a code carries unless a caller states otherwise
        /// (a CLI command that failed, for example).
        public var defaultLevel: Level {
            switch self {
            case .captureFailed, .indexRebuildFailed, .archiveAppendFailed:
                return .error
            case .secondInstanceRefused, .settingsFallback, .settingsLastGoodUsed, .indexUpsertFailed,
                 .pointerPublishFailed, .indexMissingDetected, .indexCorruptDetected, .archiveTailRepaired:
                return .warn
            default:
                return .info
            }
        }
    }

    /// CLI verbs, closed: an unrecognised word is recorded as `unknown`, so
    /// a typo on a command line can never be written to disk verbatim.
    public enum Verb: String, Codable, Sendable, CaseIterable {
        /// Not a CLI row.
        case notApplicable = ""
        case selfTest = "self-test"
        case monitor, search, redact, prune, bulk
        case sweepExpired = "sweep-expired"
        case repairIndex = "repair-index"
        case indexSearch = "index-search"
        case health, stores, logs, backup, status, verify
        case writeManifest = "write-manifest"
        case help
        case unknown

        /// Maps a raw command word onto the closed set.
        public init(command: String) {
            self = Verb(rawValue: command).flatMap { $0 == .notApplicable ? nil : $0 } ?? .unknown
        }
    }

    /// The exact field list every row carries, sorted — the documented
    /// schema, in one place, so the README, the reader and the schema test
    /// cannot drift apart.
    public static let rowFields = [
        "build", "bytes", "captures", "code", "component", "count", "durationMs",
        "errno", "level", "pid", "polls", "rssBytes", "schema", "timestamp",
        "verb", "version"
    ]

    public static let schemaVersion = 1
    public static let fileBaseName = "operational"

    private struct Row: Encodable {
        let schema = ClipboardOperationalLog.schemaVersion
        let timestamp: Date
        let pid: Int
        let version: [Int]
        let build: Int
        let level: Level
        let component: Component
        let code: Code
        let errno: Int
        let count: Int
        let durationMs: Double
        let bytes: Int
        let polls: Int
        let captures: Int
        let rssBytes: Int
        let verb: Verb
    }

    public let directory: URL
    public let maximumFileBytes: Int
    public let retainedFiles: Int

    /// The directory is passed explicitly — the app, the CLI and a test each
    /// resolve it once (`ClipboardStoreResolution.logDirectory`) and hand it
    /// in, so no surface can quietly log somewhere else.
    public init(directory: URL, maximumFileBytes: Int = 2 * 1_048_576, retainedFiles: Int = 5) {
        self.directory = directory
        self.maximumFileBytes = max(512, maximumFileBytes)
        self.retainedFiles = max(1, min(10, retainedFiles))
    }

    public var file: ClipboardRotatingLogFile {
        ClipboardRotatingLogFile(
            directory: directory,
            baseName: Self.fileBaseName,
            maximumFileBytes: maximumFileBytes,
            retainedFiles: retainedFiles
        )
    }

    /// Best effort, exactly like the usage log: a log that cannot be written
    /// returns false and never interrupts the action it was describing.
    @discardableResult
    public func record(
        _ code: Code,
        level: Level? = nil,
        errno errnoValue: Int32 = 0,
        count: Int = 0,
        durationMs: Double = 0,
        bytes: Int = 0,
        polls: Int = 0,
        captures: Int = 0,
        rssBytes: Int = 0,
        verb: Verb = .notApplicable
    ) -> Bool {
        let failureState = ClipboardFailureState(logDirectory: directory)
        let persistentCodes: Set<Code> = [.captureFailed, .archiveAppendFailed, .indexUpsertFailed, .indexRebuildFailed]
        if persistentCodes.contains(code) { _ = failureState.update(add: code.rawValue) }
        if code == .captureRecovered { _ = failureState.update(remove: ["capture_failed", "archive_append_failed"]) }
        if code == .indexRebuildFinished { _ = failureState.update(remove: ["index_upsert_failed", "index_rebuild_failed"]) }
        let identity = ClipboardRotatingLogFile.bundleVersion()
        guard let data = try? ClipboardRotatingLogFile.rowEncoder().encode(Row(
            timestamp: ClipboardRuntime.now,
            pid: Int(getpid()),
            version: identity.version,
            build: identity.build,
            level: level ?? code.defaultLevel,
            component: code.component,
            code: code,
            errno: Int(errnoValue),
            count: max(0, count),
            durationMs: durationMs.isFinite ? max(0, durationMs) : 0,
            bytes: max(0, bytes),
            polls: max(0, polls),
            captures: max(0, captures),
            rssBytes: max(0, rssBytes),
            verb: verb
        )) else {
            return false
        }
        let appended = file.append(data)
        if !appended { _ = failureState.update(add: "log_unavailable") }
        else if unresolvedFailures.contains("log_unavailable") { _ = failureState.update(remove: ["log_unavailable"]) }
        return appended
    }
}

/// One decoded row, as a reader surface needs it: the closed-enum fields as
/// text, the numeric fields by name, and the original line for `--json`.
public struct ClipboardOperationalLogEntry: Sendable, Equatable {
    /// Numeric fields in the order a text line prints them.
    public static let numericFields = [
        "pid", "errno", "count", "durationMs", "bytes", "polls", "captures", "rssBytes"
    ]

    public var timestamp: Date?
    public var timestampText: String
    public var level: String
    public var component: String
    public var code: String
    public var verb: String
    public var numbers: [String: Double]
    /// The row exactly as it was written.
    public var line: String

    /// Fields a row must show even when they are zero, by code. A
    /// heartbeat that says `polls=0` is the dead-man signal itself — the
    /// poll timer stopped while the process lived — so suppressing it as
    /// "uninteresting" would hide the one number this log exists for.
    public static let alwaysShownFields: [String: Set<String>] = [
        "heartbeat": ["polls", "captures", "rssBytes"]
    ]

    /// One line: when, how bad, what, and the numbers that carry
    /// information for this row.
    public var textDescription: String {
        var parts = [timestampText, level, component, code]
        if !verb.isEmpty {
            parts.append("verb=\(verb)")
        }
        let alwaysShown = Self.alwaysShownFields[code] ?? []
        for field in Self.numericFields {
            guard let value = numbers[field], value != 0 || alwaysShown.contains(field) else {
                continue
            }
            let rendered = value.rounded() == value && abs(value) < 1e15
                ? String(Int(value))
                : String(value)
            parts.append("\(field)=\(rendered)")
        }
        return parts.joined(separator: " ")
    }
}

extension ClipboardOperationalLog {
    /// Reads the rotated set oldest-first and returns the newest `limit`
    /// rows that pass the filters. Unreadable files and undecodable lines
    /// are skipped rather than failing the read: a truncated tail after a
    /// crash must not cost a person the rest of the log.
    public func read(
        limit: Int = 50,
        errorsOnly: Bool = false,
        since: Date? = nil
    ) -> [ClipboardOperationalLogEntry] {
        // Newest generation first, so a small `--tail` stops after one
        // file instead of parsing every retained byte; the collected
        // chunks are re-ordered oldest-first before they are returned.
        var chunks: [[ClipboardOperationalLogEntry]] = []
        var collected = 0
        for url in file.files {
            guard let contents = try? String(contentsOf: url, encoding: .utf8) else {
                continue
            }
            var chunk: [ClipboardOperationalLogEntry] = []
            for line in contents.split(separator: "\n", omittingEmptySubsequences: true) {
                guard let entry = Self.entry(from: String(line)) else {
                    continue
                }
                if errorsOnly, entry.level != Level.error.rawValue {
                    continue
                }
                if since != nil, entry.timestamp == nil {
                    continue
                }
                if let since, let stamp = entry.timestamp, stamp < since {
                    continue
                }
                chunk.append(entry)
            }
            chunks.append(chunk)
            collected += chunk.count
            if limit > 0, collected >= limit {
                break
            }
        }
        let entries = chunks.reversed().flatMap { $0 }
        guard limit > 0, entries.count > limit else {
            return entries
        }
        return Array(entries.suffix(limit))
    }

    static func entry(from line: String) -> ClipboardOperationalLogEntry? {
        guard let data = line.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        let timestampText = object["timestamp"] as? String ?? ""
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        var numbers: [String: Double] = [:]
        for field in ClipboardOperationalLogEntry.numericFields {
            if let value = object[field] as? NSNumber {
                numbers[field] = value.doubleValue
            }
        }
        return ClipboardOperationalLogEntry(
            timestamp: formatter.date(from: timestampText),
            timestampText: timestampText,
            level: object["level"] as? String ?? "",
            component: object["component"] as? String ?? "",
            code: object["code"] as? String ?? "",
            verb: object["verb"] as? String ?? "",
            numbers: numbers,
            line: line
        )
    }
}
