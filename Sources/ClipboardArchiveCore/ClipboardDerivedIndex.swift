import Darwin
import Foundation

/// Structured query filters for the derived index (contract 3). All fields
/// are optional and combine with AND. `contentType` is a raw string rather
/// than `ClipboardContentType` so future/unknown type values filter without
/// a code change (tolerance-friendly).
public struct ClipboardIndexSearchFilters: Equatable, Sendable {
    /// Inclusive lower bound on capture time.
    public var since: Date?
    /// Inclusive upper bound on capture time.
    public var until: Date?
    public var bundleID: String?
    public var sourceAppName: String?
    public var contentType: String?

    public init(
        since: Date? = nil,
        until: Date? = nil,
        bundleID: String? = nil,
        sourceAppName: String? = nil,
        contentType: String? = nil
    ) {
        self.since = since
        self.until = until
        self.bundleID = bundleID
        self.sourceAppName = sourceAppName
        self.contentType = contentType
    }
}

/// One structured hit from the derived index. `snippet` is the FTS match
/// snippet for searches and the stored preview for browsing.
public struct ClipboardIndexSearchResult: Equatable, Sendable {
    public var id: String
    public var capturedAt: Date
    public var sourceApp: String
    public var bundleID: String?
    public var contentType: String
    public var snippet: String
    public var byteCount: Int

    public init(
        id: String,
        capturedAt: Date,
        sourceApp: String,
        bundleID: String?,
        contentType: String,
        snippet: String,
        byteCount: Int
    ) {
        self.id = id
        self.capturedAt = capturedAt
        self.sourceApp = sourceApp
        self.bundleID = bundleID
        self.contentType = contentType
        self.snippet = snippet
        self.byteCount = byteCount
    }
}

public struct ClipboardDerivedIndex: Sendable {
    /// Stored as `PRAGMA user_version` in the index database. 0 means a
    /// pre-versioning index (SQLite's default for databases that never set
    /// it); any mismatch triggers a full rebuild — the index is disposable
    /// derived data and rebuild is always the recovery path (contract 3).
    public static let currentIndexSchemaVersion = 2

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
            // The rebuild is the ONE place the schema version gets stamped:
            // the temp-db + quick_check + atomic-replace flow guarantees a
            // stamped database is also a fully populated v2 database.
            try writeSQL("""
            PRAGMA journal_mode=OFF;
            PRAGMA synchronous=OFF;
            PRAGMA user_version=\(Self.currentIndexSchemaVersion);
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
                    INSERT INTO clipboard_meta(id,captured_at,source_app,bundle_id,content_type,byte_count,raw_content_path,content_hash,preview) VALUES('\(escape(event.id))','\(escape(iso(event.capturedAt)))','\(escape(event.sourceApp.name))','\(escape(event.sourceApp.bundleIdentifier ?? ""))','\(escape(event.contentType.rawValue))',\(event.byteCount),'\(escape(event.rawContentPath ?? ""))','\(escape(event.contentHash))','\(escape(event.contentPreview))');
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
        // Outside the exclusive lock: ensure/rebuild takes the lock itself
        // (the lock is not reentrant). A racing ensure from another process
        // is an idempotent double rebuild.
        try ensureCurrentSchema()
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
            INSERT INTO clipboard_meta(id,captured_at,source_app,bundle_id,content_type,byte_count,raw_content_path,content_hash,preview) VALUES('\(escape(event.id))','\(escape(iso(event.capturedAt)))','\(escape(event.sourceApp.name))','\(escape(event.sourceApp.bundleIdentifier ?? ""))','\(escape(event.contentType.rawValue))',\(event.byteCount),'\(escape(event.rawContentPath ?? ""))','\(escape(event.contentHash))','\(escape(event.contentPreview))');
            COMMIT;
            """)
            try ClipboardPrivateFileSystem.secureFile(indexURL)
        }
    }

    // MARK: - Schema versioning (contract 3)

    /// True when the index file exists and its `PRAGMA user_version` matches
    /// `currentIndexSchemaVersion`. Any read failure (missing file, corrupt
    /// header, unreadable pragma) reports false so the caller heals with a
    /// rebuild.
    public func schemaIsCurrent() -> Bool {
        guard FileManager.default.fileExists(atPath: indexURL.path) else {
            return false
        }
        guard let rows = try? runSQLiteJSON(
            "SELECT user_version AS user_version FROM pragma_user_version;"
        ),
            let version = rows.first?["user_version"] as? Int else {
            return false
        }
        return version == Self.currentIndexSchemaVersion
    }

    /// Rebuilds the index when it is missing or its schema version does not
    /// match the current one. Must be called OUTSIDE `withExclusiveLock`
    /// (the lock is not reentrant; `rebuild()` acquires it). Two processes
    /// racing here at worst perform an idempotent double rebuild. A failed
    /// rebuild throws and leaves any prior index file untouched (the rebuild
    /// flow only replaces the file after `quick_check` passes).
    @discardableResult
    public func ensureCurrentSchema() throws -> Bool {
        // Per-capture cost guard: without this cache every accepted capture
        // spawns an extra sqlite3 subprocess on the main thread just to
        // re-read user_version. Once this process has verified (or built)
        // the schema, trust it. An external process swapping in an
        // older-schema file mid-run degrades to a failed upsert (already
        // non-fatal) and heals through the manual/CLI rebuild path.
        if Self.verifiedSchemaPaths.contains(indexURL.path) {
            return false
        }
        guard !schemaIsCurrent() else {
            Self.verifiedSchemaPaths.insert(indexURL.path)
            return false
        }
        _ = try rebuild()
        Self.verifiedSchemaPaths.insert(indexURL.path)
        return true
    }

    private static let verifiedSchemaPaths = VerifiedPathSet()

    private final class VerifiedPathSet: @unchecked Sendable {
        private let lock = NSLock()
        private var paths: Set<String> = []

        func contains(_ path: String) -> Bool {
            lock.lock()
            defer {
                lock.unlock()
            }
            return paths.contains(path)
        }

        func insert(_ path: String) {
            lock.lock()
            defer {
                lock.unlock()
            }
            paths.insert(path)
        }
    }

    // MARK: - Structured queries (contract 3)

    /// Full-text search returning structured rows. The user query is
    /// tokenized on whitespace and every token is individually quote-escaped
    /// (implicit AND), so user-typed FTS operators (`OR`, `NEAR`, `*`, `-`,
    /// `^`, quotes) are matched literally and can never change query
    /// structure. An effectively empty query falls back to `browse`.
    public func structuredSearch(
        _ query: String,
        filters: ClipboardIndexSearchFilters = ClipboardIndexSearchFilters(),
        limit: Int = 100
    ) throws -> [ClipboardIndexSearchResult] {
        let matchExpression = ftsMatchExpression(query)
        guard !matchExpression.isEmpty else {
            return try browse(filters: filters, limit: limit)
        }
        try ensureCurrentSchema()
        let boundedLimit = max(1, min(limit, 500))
        // `m.content_type <> 'blocked'` is defense in depth: blocked events
        // never reach the index writers, so any such row is foreign data.
        // The FTS table stays unaliased — sqlite3's FTS5 aux functions
        // (snippet) do not accept a table alias here.
        let sql = """
        SELECT m.id AS id, m.captured_at AS captured_at, m.source_app AS source_app,
               m.bundle_id AS bundle_id, m.content_type AS content_type,
               m.byte_count AS byte_count,
               snippet(clipboard_fts, 5, '', '', ' … ', 24) AS snip
        FROM clipboard_fts
        JOIN clipboard_meta m ON m.id = clipboard_fts.id
        WHERE clipboard_fts MATCH '\(escape(matchExpression))'
          AND m.content_type <> 'blocked'\(filterSQL(filters, columnPrefix: "m."))
        ORDER BY m.captured_at DESC
        LIMIT \(boundedLimit);
        """
        return try suppressionFiltered(results(fromRows: runSQLiteJSON(sql)))
    }

    /// Empty-query browsing straight off `clipboard_meta` (no FTS join; the
    /// stored `preview` column stands in for a match snippet).
    public func browse(
        filters: ClipboardIndexSearchFilters = ClipboardIndexSearchFilters(),
        limit: Int = 100
    ) throws -> [ClipboardIndexSearchResult] {
        try ensureCurrentSchema()
        let boundedLimit = max(1, min(limit, 500))
        let sql = """
        SELECT id AS id, captured_at AS captured_at, source_app AS source_app,
               bundle_id AS bundle_id, content_type AS content_type,
               byte_count AS byte_count, COALESCE(preview, '') AS snip
        FROM clipboard_meta
        WHERE content_type <> 'blocked'\(filterSQL(filters, columnPrefix: ""))
        ORDER BY captured_at DESC
        LIMIT \(boundedLimit);
        """
        return try suppressionFiltered(results(fromRows: runSQLiteJSON(sql)))
    }

    /// Distinct source app names for the UI filter popup.
    public func distinctSourceApps() throws -> [String] {
        try ensureCurrentSchema()
        let rows = try runSQLiteJSON("""
        SELECT DISTINCT source_app AS source_app
        FROM clipboard_meta
        WHERE content_type <> 'blocked' AND source_app <> ''
        ORDER BY source_app COLLATE NOCASE;
        """)
        return rows.compactMap { $0["source_app"] as? String }
    }

    /// Read-time suppression parity (contract 6): a rebuilt-from-stale-state
    /// index plus later ledger appends must not leak deleted clips, so ids
    /// in the deletion ledger are dropped here even though `rebuild()`
    /// already excludes them. Post-filtering can under-fill the caller's
    /// `limit`; that is acceptable — drifted rows heal on the next rebuild.
    private func suppressionFiltered(
        _ results: [ClipboardIndexSearchResult]
    ) throws -> [ClipboardIndexSearchResult] {
        let suppression = try ClipboardSuppression(archiveRoot: archiveRoot).snapshot()
        return results.filter { !suppression.deletedIDs.contains($0.id) }
    }

    private func results(fromRows rows: [[String: Any]]) -> [ClipboardIndexSearchResult] {
        let parser = ISO8601DateFormatter()
        return rows.compactMap { row in
            guard let id = row["id"] as? String,
                  let capturedRaw = row["captured_at"] as? String,
                  let capturedAt = parser.date(from: capturedRaw) else {
                return nil
            }
            let bundleID = (row["bundle_id"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            return ClipboardIndexSearchResult(
                id: id,
                capturedAt: capturedAt,
                sourceApp: row["source_app"] as? String ?? "",
                bundleID: bundleID,
                contentType: row["content_type"] as? String ?? "",
                snippet: row["snip"] as? String ?? "",
                byteCount: row["byte_count"] as? Int ?? 0
            )
        }
    }

    /// `captured_at` is fixed-width ISO 8601 UTC, so lexicographic string
    /// comparison equals chronological comparison and both bounds stay
    /// inclusive and index-assisted.
    private func filterSQL(
        _ filters: ClipboardIndexSearchFilters,
        columnPrefix: String
    ) -> String {
        var clauses: [String] = []
        if let since = filters.since {
            clauses.append("\(columnPrefix)captured_at >= '\(escape(iso(since)))'")
        }
        if let until = filters.until {
            clauses.append("\(columnPrefix)captured_at <= '\(escape(iso(until)))'")
        }
        if let bundleID = filters.bundleID {
            clauses.append("\(columnPrefix)bundle_id = '\(escape(bundleID))'")
        }
        if let sourceAppName = filters.sourceAppName {
            clauses.append("\(columnPrefix)source_app = '\(escape(sourceAppName))'")
        }
        if let contentType = filters.contentType {
            clauses.append("\(columnPrefix)content_type = '\(escape(contentType))'")
        }
        return clauses.map { " AND \($0)" }.joined()
    }

    /// UI-path FTS escaping: whitespace-tokenize, double-quote each token
    /// with interior quotes doubled, join with spaces (implicit AND).
    /// Returns "" for an all-whitespace query.
    private func ftsMatchExpression(_ query: String) -> String {
        query
            .split(whereSeparator: { $0.isWhitespace })
            .map { "\"\(String($0).replacingOccurrences(of: "\"", with: "\"\""))\"" }
            .joined(separator: " ")
    }

    public func search(_ query: String, limit: Int = 25) throws -> String {
        let boundedLimit = max(1, min(limit, 10_000))
        // SECURITY (contract 3): the SQL — which embeds user query text —
        // streams over stdin so it never appears in process arguments,
        // where any local process could read it from the process table.
        // The raw-text output format is preserved for the CLI.
        let sql = """
        SELECT captured_at || ' ' || id || ' ' || source_app || char(10) || snippet(clipboard_fts, 5, '[', ']', ' ... ', 24)
        FROM clipboard_fts
        WHERE clipboard_fts MATCH '\(escapeFTS(query))'
        ORDER BY captured_at DESC
        LIMIT \(boundedLimit);
        """

        let process = Process()
        process.executableURL = sqliteExecutableURL
        process.arguments = ["-noheader", "-separator", "\n---\n", "-batch", indexURL.path]
        let input = Pipe()
        let output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        do {
            try input.fileHandleForWriting.write(contentsOf: Data(sql.utf8))
            try input.fileHandleForWriting.close()
        } catch {
            process.terminate()
            throw error
        }
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
        // Two layers, both required. POSIX record locks (lockf) are scoped
        // to (process, inode): two THREADS of this process on separate
        // descriptors both acquire the file lock instantly, so lockf alone
        // cannot serialize the main-thread capture upsert against the
        // panel's background search queue (a rebuild racing an upsert was
        // reproducibly shown to drop freshly indexed rows). The per-path
        // process lock closes the intra-process hole; the file lock keeps
        // covering app-vs-CLI.
        let processLock = Self.processLocks.lock(forPath: indexURL.path)
        processLock.lock()
        defer {
            processLock.unlock()
        }
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

    private static let processLocks = ProcessLockRegistry()

    /// Per-index-path in-process locks; see `withExclusiveLock` for why the
    /// file lock alone is insufficient between threads of one process.
    private final class ProcessLockRegistry: @unchecked Sendable {
        private let registryLock = NSLock()
        private var locks: [String: NSLock] = [:]

        func lock(forPath path: String) -> NSLock {
            registryLock.lock()
            defer {
                registryLock.unlock()
            }
            if let existing = locks[path] {
                return existing
            }
            let created = NSLock()
            locks[path] = created
            return created
        }
    }

    /// Runs one read query in `sqlite3 -json -batch` mode with the SQL
    /// streamed over stdin (never argv). JSON mode is the load-bearing
    /// choice: clipboard text can legally contain any in-band delimiter
    /// (0x1F/0x1E/newlines), so separator-based framing silently mis-frames
    /// rows, while JSON escapes all control characters and round-trips any
    /// valid-UTF-8 string exactly. All indexed content entered as Swift
    /// String and no column is a BLOB, so JSON-mode hazards do not apply.
    /// Quirks handled here: an empty result set emits EMPTY stdout (treated
    /// as `[]`); undecodable stdout is a typed `malformedOutput` error.
    /// Pipe discipline: write SQL + close stdin, read stdout to end, THEN
    /// waitUntilExit (avoids pipe-buffer deadlock on large results).
    func runSQLiteJSON(_ sql: String) throws -> [[String: Any]] {
        let process = Process()
        process.executableURL = sqliteExecutableURL
        process.arguments = ["-json", "-batch", indexURL.path]
        let input = Pipe()
        let output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        do {
            try input.fileHandleForWriting.write(contentsOf: Data(sql.utf8))
            try input.fileHandleForWriting.close()
        } catch {
            process.terminate()
            throw error
        }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw ClipboardDerivedIndexError.sqliteFailed(process.terminationStatus)
        }
        guard let text = String(data: data, encoding: .utf8) else {
            throw ClipboardDerivedIndexError.malformedOutput
        }
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return []
        }
        guard let parsed = try? JSONSerialization.jsonObject(with: data),
              let rows = parsed as? [[String: Any]] else {
            throw ClipboardDerivedIndexError.malformedOutput
        }
        return rows
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

    /// Schema v2: `content_hash` + its index serve duplicate grouping
    /// (Slice 4); `preview` lets empty-query browsing avoid joining into
    /// FTS on an UNINDEXED column; the `captured_at` index serves date-range
    /// scans. Old binaries INSERT with explicit column lists, so their rows
    /// simply leave the new columns NULL until the next rebuild heals them.
    private static let schemaSQL = """
    CREATE VIRTUAL TABLE IF NOT EXISTS clipboard_fts USING fts5(id UNINDEXED, captured_at UNINDEXED, source_app, content_type, preview, body);
    CREATE TABLE IF NOT EXISTS clipboard_meta(id TEXT PRIMARY KEY, captured_at TEXT, source_app TEXT, bundle_id TEXT, content_type TEXT, byte_count INTEGER, raw_content_path TEXT, content_hash TEXT, preview TEXT);
    CREATE INDEX IF NOT EXISTS clipboard_meta_captured_at_idx ON clipboard_meta(captured_at);
    CREATE INDEX IF NOT EXISTS clipboard_meta_content_hash_idx ON clipboard_meta(content_hash);
    """
}

public enum ClipboardDerivedIndexError: Error, Equatable, CustomStringConvertible, Sendable {
    case lockFailed(Int32)
    case sqliteFailed(Int32)
    case validationFailed
    case malformedOutput

    public var description: String {
        switch self {
        case let .lockFailed(status):
            return "index lock failed with errno \(status)"
        case let .sqliteFailed(status):
            return "sqlite3 failed with status \(status)"
        case .validationFailed:
            return "sqlite3 index validation failed"
        case .malformedOutput:
            return "sqlite3 produced undecodable output"
        }
    }
}
