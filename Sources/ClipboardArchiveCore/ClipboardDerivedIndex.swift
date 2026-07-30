import Darwin
import Foundation

public struct ClipboardDerivedIndex: Sendable {
    public var archiveRoot: URL
    public var indexURL: URL
    public var sqliteExecutableURL: URL

    public init(
        archiveRoot: URL,
        indexURL: URL = ClipboardDefaults.indexURL(),
        sqliteExecutableURL: URL = URL(fileURLWithPath: "/usr/bin/sqlite3")
    ) {
        self.archiveRoot = archiveRoot
        self.indexURL = indexURL
        self.sqliteExecutableURL = sqliteExecutableURL
    }

    public func rebuild() throws -> Int {
        let indexDirectory = indexURL.deletingLastPathComponent()
        try ClipboardPrivateFileSystem.createDirectory(indexDirectory, archiveRoot: indexDirectory)
        return try withExclusiveLock {
            try rebuildUnlocked(indexDirectory: indexDirectory)
        }
    }

    private func rebuildUnlocked(indexDirectory: URL) throws -> Int {
        let temporaryIndex = indexDirectory
            .appendingPathComponent(".\(indexURL.lastPathComponent).rebuild-\(UUID().uuidString)")
        let temporarySQL = indexDirectory
            .appendingPathComponent(".\(indexURL.lastPathComponent).rebuild-\(UUID().uuidString).sql")
        defer {
            if FileManager.default.fileExists(atPath: temporaryIndex.path) {
                try? FileManager.default.removeItem(at: temporaryIndex)
            }
            if FileManager.default.fileExists(atPath: temporarySQL.path) {
                try? FileManager.default.removeItem(at: temporarySQL)
            }
        }

        try Data().write(to: temporarySQL, options: [.atomic])
        try ClipboardPrivateFileSystem.secureFile(temporarySQL)
        let sqlOutput = try FileHandle(forWritingTo: temporarySQL)

        func writeSQL(_ sql: String) throws {
            try sqlOutput.write(contentsOf: Data(sql.utf8))
        }

        do {
            try writeSQL("""
            PRAGMA journal_mode=OFF;
            PRAGMA synchronous=OFF;
            \(Self.schemaSQL)
            BEGIN TRANSACTION;
            """)

            let reader = ClipboardArchiveReader(archiveRoot: archiveRoot)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let suppression = try ClipboardSuppression(archiveRoot: archiveRoot).snapshot()
            var count = 0

            for fileURL in try reader.eventFiles() {
                let lines = try String(contentsOf: fileURL)
                    .split(separator: "\n", omittingEmptySubsequences: true)
                for line in lines {
                    guard let data = String(line).data(using: .utf8),
                          let event = try? decoder.decode(StoredClipboardEvent.self, from: data),
                          !suppression.isSuppressed(event) else {
                        continue
                    }
                    let body = (try? reader.content(for: event)) ?? event.contentPreview
                    try writeSQL("""

                    INSERT INTO clipboard_fts(id,captured_at,source_app,content_type,preview,body) VALUES('\(escape(event.id))','\(escape(iso(event.capturedAt)))','\(escape(event.sourceApp.name))','\(escape(event.contentType.rawValue))','\(escape(event.contentPreview))','\(escape(body))');
                    INSERT INTO clipboard_meta(id,captured_at,source_app,bundle_id,content_type,byte_count,raw_content_path) VALUES('\(escape(event.id))','\(escape(iso(event.capturedAt)))','\(escape(event.sourceApp.name))','\(escape(event.sourceApp.bundleIdentifier ?? ""))','\(escape(event.contentType.rawValue))',\(event.byteCount),'\(escape(event.rawContentPath ?? ""))');
                    """)
                    count += 1
                }
            }

            try writeSQL("\nCOMMIT;\n")
            try sqlOutput.close()

            let process = Process()
            process.executableURL = sqliteExecutableURL
            process.arguments = [temporaryIndex.path]
            process.standardInput = try FileHandle(forReadingFrom: temporarySQL)
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else {
                throw ClipboardDerivedIndexError.sqliteFailed(process.terminationStatus)
            }
            try validateIndex(at: temporaryIndex)
            try ClipboardPrivateFileSystem.secureFile(temporaryIndex)

            if FileManager.default.fileExists(atPath: indexURL.path) {
                _ = try FileManager.default.replaceItemAt(indexURL, withItemAt: temporaryIndex)
            } else {
                try FileManager.default.moveItem(at: temporaryIndex, to: indexURL)
            }
            try ClipboardPrivateFileSystem.secureFile(indexURL)
            return count
        } catch {
            try? sqlOutput.close()
            throw error
        }
    }

    public func upsert(event: StoredClipboardEvent, body: String) throws {
        let indexDirectory = indexURL.deletingLastPathComponent()
        try ClipboardPrivateFileSystem.createDirectory(indexDirectory, archiveRoot: indexDirectory)
        try withExclusiveLock {
            if event.privacyLabel == .doNotIndex {
                _ = try deleteUnlocked(eventID: event.id)
                return
            }

            try runSQLite(input: """
            PRAGMA busy_timeout=2000;
            \(Self.schemaSQL)
            BEGIN IMMEDIATE TRANSACTION;
            DELETE FROM clipboard_fts WHERE id = '\(escape(event.id))';
            DELETE FROM clipboard_meta WHERE id = '\(escape(event.id))';
            INSERT INTO clipboard_fts(id,captured_at,source_app,content_type,preview,body) VALUES('\(escape(event.id))','\(escape(iso(event.capturedAt)))','\(escape(event.sourceApp.name))','\(escape(event.contentType.rawValue))','\(escape(event.contentPreview))','\(escape(body))');
            INSERT INTO clipboard_meta(id,captured_at,source_app,bundle_id,content_type,byte_count,raw_content_path) VALUES('\(escape(event.id))','\(escape(iso(event.capturedAt)))','\(escape(event.sourceApp.name))','\(escape(event.sourceApp.bundleIdentifier ?? ""))','\(escape(event.contentType.rawValue))',\(event.byteCount),'\(escape(event.rawContentPath ?? ""))');
            COMMIT;
            """)
            try ClipboardPrivateFileSystem.secureFile(indexURL)
        }
    }

    public func search(_ query: String, limit: Int = 25) throws -> String {
        let boundedLimit = max(1, min(limit, 10_000))
        let sql = """
        SELECT captured_at || ' ' || id || ' ' || source_app || char(10) || snippet(clipboard_fts, 5, '[', ']', ' ... ', 24)
        FROM clipboard_fts
        WHERE clipboard_fts MATCH '\(escapeFTS(query))'
        ORDER BY captured_at DESC
        LIMIT \(boundedLimit);
        """

        let process = Process()
        process.executableURL = sqliteExecutableURL
        process.arguments = ["-noheader", "-separator", "\n---\n", indexURL.path, sql]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw ClipboardDerivedIndexError.sqliteFailed(process.terminationStatus)
        }
        return String(data: data, encoding: .utf8) ?? ""
    }

    @discardableResult
    public func delete(eventID: String) throws -> Bool {
        try delete(eventIDs: [eventID])
    }

    /// Per-event index deletes batched into a single sqlite3 invocation.
    /// Used by incremental retention enforcement so pruning N events costs
    /// one process spawn instead of N (and never a full rebuild).
    @discardableResult
    public func delete(eventIDs: [String]) throws -> Bool {
        guard !eventIDs.isEmpty else {
            return false
        }
        let indexDirectory = indexURL.deletingLastPathComponent()
        try ClipboardPrivateFileSystem.createDirectory(indexDirectory, archiveRoot: indexDirectory)
        return try withExclusiveLock {
            guard FileManager.default.fileExists(atPath: indexURL.path) else {
                return false
            }

            var sql = "PRAGMA busy_timeout=2000;\nBEGIN IMMEDIATE TRANSACTION;\n"
            for eventID in eventIDs {
                sql += """
                DELETE FROM clipboard_fts WHERE id = '\(escape(eventID))';
                DELETE FROM clipboard_meta WHERE id = '\(escape(eventID))';

                """
            }
            sql += "COMMIT;\n"
            try runSQLite(input: sql)
            return true
        }
    }

    private func deleteUnlocked(eventID: String) throws -> Bool {
        guard FileManager.default.fileExists(atPath: indexURL.path) else {
            return false
        }

        let sql = """
        PRAGMA busy_timeout=2000;
        DELETE FROM clipboard_fts WHERE id = '\(escape(eventID))';
        DELETE FROM clipboard_meta WHERE id = '\(escape(eventID))';
        """

        try runSQLite(input: sql)
        return true
    }

    private func withExclusiveLock<T>(_ body: () throws -> T) throws -> T {
        let lockURL = indexURL.deletingLastPathComponent()
            .appendingPathComponent(".\(indexURL.lastPathComponent).lock")
        let descriptor = Darwin.open(
            lockURL.path,
            O_CREAT | O_RDWR,
            S_IRUSR | S_IWUSR
        )
        guard descriptor >= 0 else {
            throw ClipboardDerivedIndexError.lockFailed(errno)
        }
        defer {
            _ = Darwin.lockf(descriptor, F_ULOCK, 0)
            _ = Darwin.close(descriptor)
        }
        guard Darwin.fchmod(descriptor, S_IRUSR | S_IWUSR) == 0,
              Darwin.lockf(descriptor, F_LOCK, 0) == 0 else {
            throw ClipboardDerivedIndexError.lockFailed(errno)
        }
        return try body()
    }

    private func runSQLite(input sql: String) throws {
        let process = Process()
        process.executableURL = sqliteExecutableURL
        process.arguments = [indexURL.path]
        let input = Pipe()
        process.standardInput = input
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        do {
            try input.fileHandleForWriting.write(contentsOf: Data(sql.utf8))
            try input.fileHandleForWriting.close()
        } catch {
            process.terminate()
            throw error
        }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw ClipboardDerivedIndexError.sqliteFailed(process.terminationStatus)
        }
    }

    private func validateIndex(at url: URL) throws {
        let process = Process()
        process.executableURL = sqliteExecutableURL
        process.arguments = [url.path, "PRAGMA quick_check;"]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        let result = String(
            data: output.fileHandleForReading.readDataToEndOfFile(),
            encoding: .utf8
        )?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard process.terminationStatus == 0, result == "ok" else {
            throw ClipboardDerivedIndexError.validationFailed
        }
    }

    private func escape(_ value: String) -> String {
        value.replacingOccurrences(of: "'", with: "''")
    }

    private func escapeFTS(_ value: String) -> String {
        "\"\(value.replacingOccurrences(of: "\"", with: "\"\""))\""
    }

    private func iso(_ date: Date) -> String {
        ISO8601DateFormatter().string(from: date)
    }

    private static let schemaSQL = """
    CREATE VIRTUAL TABLE IF NOT EXISTS clipboard_fts USING fts5(id UNINDEXED, captured_at UNINDEXED, source_app, content_type, preview, body);
    CREATE TABLE IF NOT EXISTS clipboard_meta(id TEXT PRIMARY KEY, captured_at TEXT, source_app TEXT, bundle_id TEXT, content_type TEXT, byte_count INTEGER, raw_content_path TEXT);
    """
}

public enum ClipboardDerivedIndexError: Error, Equatable, CustomStringConvertible, Sendable {
    case lockFailed(Int32)
    case sqliteFailed(Int32)
    case validationFailed

    public var description: String {
        switch self {
        case let .lockFailed(status):
            return "index lock failed with errno \(status)"
        case let .sqliteFailed(status):
            return "sqlite3 failed with status \(status)"
        case .validationFailed:
            return "sqlite3 index validation failed"
        }
    }
}
