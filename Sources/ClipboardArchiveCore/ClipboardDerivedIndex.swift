import Darwin
import Foundation
import SQLite3

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
    /// Content identity (`sha256:<hex>`) for duplicate grouping and
    /// annotation lookups. Empty when the row was indexed by an older binary
    /// that predates the column (heals on the next rebuild).
    public var contentHash: String

    public init(
        id: String,
        capturedAt: Date,
        sourceApp: String,
        bundleID: String?,
        contentType: String,
        snippet: String,
        byteCount: Int,
        contentHash: String = ""
    ) {
        self.id = id
        self.capturedAt = capturedAt
        self.sourceApp = sourceApp
        self.bundleID = bundleID
        self.contentType = contentType
        self.snippet = snippet
        self.byteCount = byteCount
        self.contentHash = contentHash
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
    /// The rebuild bulk loader only. Integrity probes, upserts, deletes and
    /// reads use SQLite in process.
    public var sqliteExecutableURL: URL
    public var sqliteTimeoutSeconds: TimeInterval
    /// Operational sink for rebuilds, passed explicitly by the surface that
    /// resolved it. Nil means silent.
    public var operationalLog: ClipboardOperationalLog?

    public init(
        archiveRoot: URL,
        indexURL: URL,
        sqliteExecutableURL: URL = URL(fileURLWithPath: "/usr/bin/sqlite3"),
        operationalLog: ClipboardOperationalLog? = nil,
        sqliteTimeoutSeconds: TimeInterval = 4
    ) {
        self.archiveRoot = archiveRoot
        self.indexURL = indexURL
        self.sqliteExecutableURL = sqliteExecutableURL
        self.sqliteTimeoutSeconds = sqliteTimeoutSeconds
        self.operationalLog = operationalLog
    }

    /// Per-kind FTS body derivation (Slice 6), shared BY CONSTRUCTION
    /// between the capture upsert and `rebuild()` so the two writers can
    /// never index different text for the same event (pinned by a parity
    /// test):
    /// - image → the stored preview text ("Image 1920×1080 (2.1 MB)"),
    /// - file lists → file NAMES only (full paths stay event-metadata-only;
    ///   "invoice.pdf" is searchable, directory structure never enters
    ///   snippets),
    /// - everything else (rtf fallback, color hex, link url+title, text) →
    ///   the plain-text fallback unchanged.
    public static func indexBody(for event: StoredClipboardEvent, plainContent: String) -> String {
        guard let rich = event.richContent else {
            return plainContent
        }
        switch rich.kind {
        case ClipboardRichContent.imageKind:
            return event.contentPreview
        case ClipboardRichContent.fileListKind:
            guard let files = rich.files, !files.isEmpty else {
                return event.contentPreview
            }
            return files.map(\.name).joined(separator: "\n")
        default:
            return plainContent
        }
    }

    public func rebuild() throws -> Int {
        let start = Date()
        let usage = ClipboardUsageLog(archiveRoot: archiveRoot)
        // A rebuild that starts and never finishes is the interesting case,
        // so the start is recorded before the work rather than after it.
        operationalLog?.record(.indexRebuildStarted)
        do {
            let indexDirectory = indexURL.deletingLastPathComponent()
            try ClipboardPrivateFileSystem.createDirectory(indexDirectory, archiveRoot: indexDirectory)
            let count = try withExclusiveLock { try rebuildUnlocked(indexDirectory: indexDirectory) }
            usage.record(.indexRebuild, scope: .index, count: count,
                durationMs: Date().timeIntervalSince(start) * 1000)
            operationalLog?.record(.indexRebuildFinished, count: count,
                durationMs: Date().timeIntervalSince(start) * 1000)
            // The rebuild replaced the file, so the verified identity is the
            // new one — recorded here for every caller, not just the
            // self-heal path.
            Self.verifiedSchemas.record(indexURL.path, stamp: Self.fileStamp(atPath: indexURL.path))
            return count
        } catch {
            usage.record(.indexRebuild, outcome: .failed, scope: .index,
                durationMs: Date().timeIntervalSince(start) * 1000)
            operationalLog?.record(.indexRebuildFailed,
                durationMs: Date().timeIntervalSince(start) * 1000)
            throw error
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

        try Data().writeClipboardAtomically(to: temporarySQL)
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
            // `.restricted` semantics (Slice 5): restricted events — by
            // stored label or by manual annotation override — are stored
            // and visible but NEVER enter the index. One annotations read
            // per rebuild.
            let restrictedHashes = ClipboardAnnotationsStore(archiveRoot: archiveRoot)
                .restrictedContentHashes()
            var count = 0

            for fileURL in try reader.eventFiles() {
                let lines = try String.readingClipboardText(contentsOf: fileURL)
                    .split(separator: "\n", omittingEmptySubsequences: true)
                for line in lines {
                    guard let data = String(line).data(using: .utf8),
                          let event = try? decoder.decode(StoredClipboardEvent.self, from: data),
                          !suppression.isSuppressed(event),
                          !ClipboardSuppression.isIndexExcluded(
                              event,
                              sensitivityOverride: restrictedHashes.contains(event.contentHash)
                                  ? "restricted"
                                  : nil
                          ) else {
                        continue
                    }
                    // Same per-kind derivation the upsert path uses
                    // (parity by construction — Slice 6).
                    let body = Self.indexBody(
                        for: event,
                        plainContent: (try? reader.content(for: event)) ?? event.contentPreview
                    )
                    try writeSQL("""

                    INSERT INTO clipboard_fts(id,captured_at,source_app,content_type,preview,body) VALUES('\(escape(event.id))','\(escape(iso(event.capturedAt)))','\(escape(event.sourceApp.name))','\(escape(event.contentType.rawValue))','\(escape(event.contentPreview))','\(escape(body))');
                    INSERT INTO clipboard_meta(id,captured_at,source_app,bundle_id,content_type,byte_count,raw_content_path,content_hash,preview) VALUES('\(escape(event.id))','\(escape(iso(event.capturedAt)))','\(escape(event.sourceApp.name))','\(escape(event.sourceApp.bundleIdentifier ?? ""))','\(escape(event.contentType.rawValue))',\(event.byteCount),'\(escape(event.rawContentPath ?? ""))','\(escape(event.contentHash))','\(escape(event.contentPreview))');
                    """)
                    count += 1
                }
            }

            try writeSQL("\nCOMMIT;\n")
            try sqlOutput.close()

            try ClipboardSQLiteProcess.run(executable: sqliteExecutableURL,
                database: temporaryIndex, input: temporarySQL, timeout: sqliteTimeoutSeconds)
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

    /// Upserts one event. `sensitivityOverride` is the annotation-store
    /// manual override for the event's content hash: index-excluded events
    /// (tombstones, `.restricted` labels, manual "restricted" overrides)
    /// DELETE-instead-of-insert so a re-copy can never resurrect an index
    /// row (Slice 5 `.restricted` semantics).
    /// Returns false when the write was DEFERRED: the index was missing or
    /// unusable and a rebuild is running on the background queue, which will
    /// pick this event up from the archive. The caller has already stored
    /// the event, so deferring costs searchability for the length of the
    /// rebuild and nothing else.
    @discardableResult
    public func upsert(
        event: StoredClipboardEvent,
        body: String,
        sensitivityOverride: String? = nil
    ) throws -> Bool {
        let indexDirectory = indexURL.deletingLastPathComponent()
        try ClipboardPrivateFileSystem.createDirectory(indexDirectory, archiveRoot: indexDirectory)
        // Outside the exclusive lock: ensure/rebuild takes the lock itself
        // (the lock is not reentrant). A racing ensure from another process
        // is an idempotent double rebuild.
        guard try ensureSchema(mode: .capturePath) != .rebuildScheduled else {
            return false
        }
        try withExclusiveLock {
            if ClipboardSuppression.isIndexExcluded(event, sensitivityOverride: sensitivityOverride) {
                _ = try deleteUnlocked(eventID: event.id)
                // This branch writes to the database too; leaving the stamp
                // stale would buy a full integrity check on the next capture.
                Self.verifiedSchemas.record(indexURL.path, stamp: Self.fileStamp(atPath: indexURL.path))
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
            // This process just changed the file, so re-stamp the cache:
            // otherwise its own write would look like an outside edit and
            // buy a full `quick_check` on the very next capture.
            Self.verifiedSchemas.record(indexURL.path, stamp: Self.fileStamp(atPath: indexURL.path))
        }
        return true
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

    /// The index database's `PRAGMA user_version`, or nil when the file is
    /// missing or unreadable (dashboard/health surface).
    public func userVersion() -> Int? {
        guard FileManager.default.fileExists(atPath: indexURL.path) else {
            return nil
        }
        guard let rows = try? runSQLiteJSON(
            "SELECT user_version AS user_version FROM pragma_user_version;"
        ) else {
            return nil
        }
        return rows.first?["user_version"] as? Int
    }

    /// Every event id the index holds.
    ///
    /// Unbounded on purpose: this is the membership half of `verify`, and a
    /// capped read would report a difference that is only the cap. Ids are
    /// short, so even a large archive is a few hundred kilobytes of strings.
    public func indexedEventIDs() throws -> Set<String> {
        let rows = try ClipboardSQLiteSearch.rows(
            indexURL: indexURL,
            sql: "SELECT id AS id FROM clipboard_meta;",
            terms: []
        )
        return Set(rows.compactMap { $0["id"] as? String })
    }

    public func indexedSearchEventIDs() throws -> Set<String> {
        let rows = try ClipboardSQLiteSearch.rows(indexURL: indexURL,
            sql: "SELECT id AS id FROM clipboard_fts;", terms: [])
        return Set(rows.compactMap { $0["id"] as? String })
    }

    /// SQLite `PRAGMA quick_check` on the live index file (dashboard
    /// "Verify Integrity"). Returns true when the database reports "ok".
    public func quickCheck() -> Bool {
        guard FileManager.default.fileExists(atPath: indexURL.path) else {
            return false
        }
        return quickCheckOutcome(at: indexURL) == .ok
    }

    /// What `quick_check` actually said, in the three answers it can give.
    /// A Bool cannot hold the third one, and collapsing it into `false` is
    /// what made a busy database look damaged.
    enum QuickCheckOutcome { case ok, damaged, undetermined }

    /// SQLite codes that mean "ask again later", never "this file is bad".
    static func isContention(_ code: Int32) -> Bool {
        code == SQLITE_BUSY || code == SQLITE_LOCKED
    }

    /// Restored to the tolerance the subprocess implementation used before the
    /// in-process swap dropped it to 2 s. It only ever costs time when the
    /// index is genuinely contended, and the alternative is calling an
    /// ordinary concurrent write a corruption.
    static let busyTimeoutMilliseconds: Int32 = 5_000

    /// Rebuilds the index when it is missing or its schema version does not
    /// match the current one. Must be called OUTSIDE `withExclusiveLock`
    /// (the lock is not reentrant; `rebuild()` acquires it). Two processes
    /// racing here at worst perform an idempotent double rebuild. A failed
    /// rebuild throws and leaves any prior index file untouched (the rebuild
    /// flow only replaces the file after `quick_check` passes).
    @discardableResult
    public func ensureCurrentSchema() throws -> Bool {
        try ensureSchema(mode: .readPath) == .rebuilt
    }

    /// Which side is asking, because the answer to "the index is unusable"
    /// differs by caller. A read can wait for a rebuild — it already runs
    /// off the main thread. A capture cannot: rebuilding a 17k-row archive
    /// takes seconds, and the capture path runs on the main thread, so it
    /// hands the work to the background queue and skips this one write.
    public enum SchemaCheckMode: Sendable {
        case readPath
        case capturePath
    }

    public enum SchemaCheckOutcome: Equatable, Sendable {
        /// The file on disk is the index this process already verified, or
        /// it passed a fresh integrity check.
        case verified
        /// It was missing or unusable and has been rebuilt; reads and writes
        /// may proceed.
        case rebuilt
        /// It was missing or unusable and a rebuild is running on the
        /// background queue; a capture-path write skips instead of blocking.
        case rebuildScheduled
    }

    /// Verifies — and heals — the index this instance points at.
    ///
    /// The per-process cache is keyed on the file's IDENTITY (device, inode,
    /// size, mtime), not merely on its path. That is the whole fix: a cache
    /// that remembers only "this path was fine once" keeps handing work to
    /// an index somebody deleted, and the sqlite3 CLI silently CREATES an
    /// empty database on open, so history quietly shrinks to whatever was
    /// captured after the deletion.
    ///
    /// Cost discipline: the cheap `stat` runs on every call, while
    /// `PRAGMA quick_check` (a full scan of a 65 MB file) runs ONLY when the
    /// identity changed since this process last verified it — that is, when
    /// something outside this process wrote to the file. Our own writes
    /// re-stamp the cache, so a steady stream of captures pays one stat each
    /// and nothing more.
    @discardableResult
    public func ensureSchema(mode: SchemaCheckMode) throws -> SchemaCheckOutcome {
        let path = indexURL.path
        guard let stamp = Self.fileStamp(atPath: path) else {
            Self.verifiedSchemas.forget(path)
            operationalLog?.record(.indexMissingDetected, count: 1)
            return try heal(mode: mode)
        }
        if Self.verifiedSchemas.stamp(forPath: path) == stamp {
            return .verified
        }
        switch integrityProbe() {
        case let .readable(userVersion) where userVersion == Self.currentIndexSchemaVersion:
            Self.verifiedSchemas.record(path, stamp: Self.fileStamp(atPath: path))
            return .verified
        case .undetermined:
            // Another writer holds the database. That is a live index, not a
            // damaged one, and rebuilding a healthy database because a lock
            // was busy would be the expensive wrong answer. Nothing is
            // cached, so the next call checks again.
            return .verified
        case .readable, .damaged:
            Self.verifiedSchemas.forget(path)
            operationalLog?.record(.indexCorruptDetected, count: 1)
            return try heal(mode: mode)
        }
    }

    enum IntegrityProbe: Equatable {
        /// The database answered: it passed `quick_check` and reported this
        /// schema version.
        case readable(userVersion: Int)
        /// It answered, and the answer was bad.
        case damaged
        /// It could not be asked — a busy lock, a sqlite3 that would not
        /// run. Not evidence of damage.
        case undetermined
    }

    /// Native SQLite avoids subprocess pipe/deadline hazards for probes.
    func integrityProbe() -> IntegrityProbe {
        var database: OpaquePointer?
        let opened = sqlite3_open_v2(indexURL.path, &database, SQLITE_OPEN_READONLY, nil)
        guard opened == SQLITE_OK, let database else {
            if let database { sqlite3_close(database) }
            return .undetermined
        }
        defer { sqlite3_close(database) }
        sqlite3_busy_timeout(database, Self.busyTimeoutMilliseconds)
        var statement: OpaquePointer?
        // `prepare_v2` can return BUSY too, and calling that damage is the same
        // mistake one statement earlier.
        let prepared = sqlite3_prepare_v2(database, "PRAGMA user_version", -1, &statement, nil)
        guard prepared == SQLITE_OK, let statement else {
            return Self.isContention(prepared) ? .undetermined : .damaged
        }
        defer { sqlite3_finalize(statement) }
        let result = sqlite3_step(statement)
        if Self.isContention(result) { return .undetermined }
        guard result == SQLITE_ROW else { return .damaged }
        let version = Int(sqlite3_column_int(statement, 0))
        switch quickCheckOutcome(at: indexURL) {
        case .ok: return .readable(userVersion: version)
        case .undetermined: return .undetermined
        case .damaged: return .damaged
        }
    }

    private func heal(mode: SchemaCheckMode) throws -> SchemaCheckOutcome {
        switch mode {
        case .readPath:
            _ = try rebuild()
            Self.verifiedSchemas.record(indexURL.path, stamp: Self.fileStamp(atPath: indexURL.path))
            return .rebuilt
        case .capturePath:
            // A process that has never verified this index yet is starting
            // cold — a fresh install, or the first capture after launch —
            // and building it here is the behaviour every caller already
            // expects. The stall this avoids is the MID-RUN one: an index
            // that was verified and then vanished, where a rebuild of a
            // large archive would freeze the capture path for seconds.
            guard Self.verifiedSchemas.hasEverVerified(indexURL.path) else {
                _ = try rebuild()
                Self.verifiedSchemas.record(indexURL.path, stamp: Self.fileStamp(atPath: indexURL.path))
                return .rebuilt
            }
            scheduleBackgroundRebuild()
            return .rebuildScheduled
        }
    }

    /// One rebuild per index path at a time, on a queue owned by this type,
    /// so a burst of captures against a deleted index cannot stack rebuilds.
    private func scheduleBackgroundRebuild() {
        let path = indexURL.path
        // Every deferral is counted BEFORE the rebuild claims a generation,
        // so a capture that arrives after the rebuild has scanned its day file
        // cannot be left out of the index forever: the counter moved, and
        // one more pass follows.
        Self.verifiedSchemas.noteDeferral(path)
        // BACKOFF, because serialising alone is not a failure policy. Once a
        // rebuild fails for a reason that will not change in a second — an
        // archive big enough to blow the sqlite deadline, a full disk, a
        // read-only volume — every later capture calls back into here and arms
        // another attempt that burns the whole deadline and fails the same way.
        // Search never returns, the durable ledger keeps `index_rebuild_failed`
        // (only a FINISHED rebuild clears it), and the machine does that forever
        // with nobody watching. That is precisely the "three months untouched"
        // failure this class of code is judged against.
        guard !Self.verifiedSchemas.rebuildIsBackedOff(path) else { return }
        guard let generation = Self.verifiedSchemas.beginRebuild(path) else {
            return
        }
        let index = self
        Self.rebuildQueue.async {
            let succeeded = (try? index.rebuild()) != nil
            if succeeded {
                Self.verifiedSchemas.record(path, stamp: Self.fileStamp(atPath: path))
                Self.verifiedSchemas.noteRebuildSuccess(path)
            } else {
                Self.verifiedSchemas.noteRebuildFailure(path)
            }
            let deferrals = Self.verifiedSchemas.deferrals(path)
            Self.verifiedSchemas.endRebuild(path)
            if succeeded, deferrals > generation {
                index.scheduleBackgroundRebuild()
            }
        }
    }

    /// Test and shutdown hook: waits until no background rebuild is in
    /// flight, returning false if it is still running at the deadline.
    @discardableResult
    public static func waitForPendingRebuilds(
        forIndexAt indexURL: URL? = nil,
        timeout: TimeInterval = 30
    ) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while verifiedSchemas.hasPendingRebuilds(forPath: indexURL?.path) {
            if Date() >= deadline {
                return false
            }
            usleep(50_000)
        }
        return true
    }

    /// File identity as the cache stores it. Size and mtime catch an
    /// in-place edit; device and inode catch a swap, a replace, or a
    /// delete-and-recreate that happens to land on the same size.
    struct FileStamp: Equatable, Sendable {
        var device: Int64
        var inode: UInt64
        var size: Int64
        var modifiedSeconds: Int64
        var modifiedNanoseconds: Int64
    }

    static func fileStamp(atPath path: String) -> FileStamp? {
        var info = stat()
        guard lstat(path, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else {
            return nil
        }
        return FileStamp(
            device: Int64(info.st_dev),
            inode: UInt64(info.st_ino),
            size: Int64(info.st_size),
            modifiedSeconds: Int64(info.st_mtimespec.tv_sec),
            modifiedNanoseconds: Int64(info.st_mtimespec.tv_nsec)
        )
    }

    private static let rebuildQueue = DispatchQueue(label: "app.clipboardarchive.index-rebuild")

    private static let verifiedSchemas = VerifiedSchemaCache()

    /// Internal rather than private so the rebuild BACKOFF can be tested
    /// directly. Proving it through the public rebuild path would mean
    /// manufacturing a real rebuild failure and then waiting out a real delay,
    /// which is a slow test that proves less.
    final class VerifiedSchemaCache: @unchecked Sendable {
        private let lock = NSLock()
        private var stamps: [String: FileStamp] = [:]
        private var rebuilding: Set<String> = []
        /// Paths this process has verified at least once, ever. Unlike
        /// `stamps` it is never cleared: it answers "was this index working
        /// a moment ago", which is what separates a cold start from a
        /// mid-run disappearance.
        private var everVerified: Set<String> = []
        /// How many capture-path writes have been handed to a rebuild for
        /// each path. Only ever compared against itself.
        private var deferrals: [String: Int] = [:]

        func stamp(forPath path: String) -> FileStamp? {
            lock.lock()
            defer {
                lock.unlock()
            }
            return stamps[path]
        }

        func record(_ path: String, stamp: FileStamp?) {
            lock.lock()
            defer {
                lock.unlock()
            }
            stamps[path] = stamp
            if stamp != nil {
                everVerified.insert(path)
            }
        }

        func hasEverVerified(_ path: String) -> Bool {
            lock.lock()
            defer {
                lock.unlock()
            }
            return everVerified.contains(path)
        }

        func forget(_ path: String) {
            lock.lock()
            defer {
                lock.unlock()
            }
            stamps[path] = nil
        }

        /// Takes ownership of the rebuild for `path`, returning the deferral
        /// count at that moment, or nil when a rebuild is already running.
        func beginRebuild(_ path: String) -> Int? {
            lock.lock()
            defer {
                lock.unlock()
            }
            guard rebuilding.insert(path).inserted else {
                return nil
            }
            return deferrals[path] ?? 0
        }

        @discardableResult
        func noteDeferral(_ path: String) -> Int {
            lock.lock()
            defer {
                lock.unlock()
            }
            let next = (deferrals[path] ?? 0) + 1
            deferrals[path] = next
            return next
        }

        func deferrals(_ path: String) -> Int {
            lock.lock()
            defer {
                lock.unlock()
            }
            return deferrals[path] ?? 0
        }

        func endRebuild(_ path: String) {
            lock.lock()
            defer {
                lock.unlock()
            }
            rebuilding.remove(path)
        }

        /// Consecutive failed rebuilds per path, and the uptime before which
        /// the next attempt is pointless.
        private var failures: [String: Int] = [:]
        private var blockedUntil: [String: TimeInterval] = [:]

        /// Exponential, capped at five minutes: 2s, 4s, 8s ... 300s.
        func noteRebuildFailure(_ path: String) {
            lock.lock()
            defer {
                lock.unlock()
            }
            let count = (failures[path] ?? 0) + 1
            failures[path] = count
            let delay = min(300, pow(2.0, Double(min(count, 8))))
            blockedUntil[path] = ProcessInfo.processInfo.systemUptime + delay
        }

        func noteRebuildSuccess(_ path: String) {
            lock.lock()
            defer {
                lock.unlock()
            }
            failures[path] = nil
            blockedUntil[path] = nil
        }

        func rebuildIsBackedOff(_ path: String) -> Bool {
            lock.lock()
            defer {
                lock.unlock()
            }
            guard let until = blockedUntil[path] else { return false }
            return ProcessInfo.processInfo.systemUptime < until
        }

        func hasPendingRebuilds(forPath path: String?) -> Bool {
            lock.lock()
            defer {
                lock.unlock()
            }
            guard let path else {
                return !rebuilding.isEmpty
            }
            return rebuilding.contains(path)
        }
    }

    // MARK: - Structured queries (contract 3)

    /// Literal substring search over complete indexed bodies, previews, app
    /// names and types. No FTS grammar or LIKE wildcards reach the query.
    /// The existing schema is sufficient, so upgrading needs no rebuild.
    public func structuredSearch(
        _ query: String,
        filters: ClipboardIndexSearchFilters = ClipboardIndexSearchFilters(),
        limit: Int = 100
    ) throws -> [ClipboardIndexSearchResult] {
        let terms = ClipboardSearchText.terms(query)
        guard !terms.isEmpty else {
            return try browse(filters: filters, limit: limit)
        }
        try ensureCurrentSchema()
        let boundedLimit = max(1, min(limit, Self.metaRowsMaximumLimit))
        let textSQL = "COALESCE(f.body, '') || ' ' || COALESCE(f.preview, '') || ' ' || COALESCE(f.source_app, '') || ' ' || COALESCE(f.content_type, '')"
        let sql = """
        SELECT m.id AS id, m.captured_at AS captured_at, m.source_app AS source_app,
               m.bundle_id AS bundle_id, m.content_type AS content_type,
               m.byte_count AS byte_count, COALESCE(m.content_hash, '') AS content_hash,
               clipboard_snippet(COALESCE(f.body, f.preview, '')) AS snip
        FROM clipboard_fts f
        JOIN clipboard_meta m ON m.id = f.id
        WHERE m.content_type <> 'blocked'
          AND clipboard_matches(\(textSQL))\(filterSQL(filters, columnPrefix: "m."))
        ORDER BY m.captured_at DESC
        LIMIT \(boundedLimit);
        """
        let rows = try ClipboardSQLiteSearch.rows(indexURL: indexURL, sql: sql, terms: terms)
        return try suppressionFiltered(results(fromRows: rows))
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
               byte_count AS byte_count, COALESCE(content_hash, '') AS content_hash,
               COALESCE(preview, '') AS snip
        FROM clipboard_meta
        WHERE content_type <> 'blocked'\(filterSQL(filters, columnPrefix: ""))
        ORDER BY captured_at DESC
        LIMIT \(boundedLimit);
        """
        return try suppressionFiltered(results(fromRows: runSQLiteJSON(sql)))
    }

    /// Hard cap for `metaRows`: duplicate grouping in All History scope
    /// groups over at most this many most-recent rows, and the UI footer
    /// states the cap when it is hit.
    public static let metaRowsMaximumLimit = 5_000

    /// Meta-only rows for duplicate grouping (no FTS join; the stored
    /// preview stands in for a snippet). Grouping and counting happen in
    /// Swift AFTER read-time suppression — never as SQL GROUP BY — because
    /// the deletion ledger cannot be consulted inside SQL, and counts must
    /// stay honest under index drift.
    public func metaRows(
        filters: ClipboardIndexSearchFilters = ClipboardIndexSearchFilters(),
        limit: Int = ClipboardDerivedIndex.metaRowsMaximumLimit
    ) throws -> [ClipboardIndexSearchResult] {
        try ensureCurrentSchema()
        let boundedLimit = max(1, min(limit, Self.metaRowsMaximumLimit))
        let sql = """
        SELECT id AS id, captured_at AS captured_at, source_app AS source_app,
               bundle_id AS bundle_id, content_type AS content_type,
               byte_count AS byte_count, COALESCE(content_hash, '') AS content_hash,
               COALESCE(preview, '') AS snip
        FROM clipboard_meta
        WHERE content_type <> 'blocked'\(filterSQL(filters, columnPrefix: ""))
        ORDER BY captured_at DESC
        LIMIT \(boundedLimit);
        """
        return try suppressionFiltered(results(fromRows: runSQLiteJSON(sql)))
    }

    /// Occurrence ids for one content hash, newest first, straight off the
    /// `content_hash` index. Deliberately does NOT ensure/rebuild the schema:
    /// callers (`ClipboardOccurrenceResolver`) treat a missing or unreadable
    /// index as "fall back to one reader scan" instead of triggering a full
    /// rebuild mid-delete. Results are NOT suppression-filtered here — the
    /// resolver drops ledger-deleted ids so a stale index cannot keep an
    /// annotation alive.
    public func occurrenceIDs(contentHash: String) throws -> [String] {
        let rows = try runSQLiteJSON("""
        SELECT id AS id
        FROM clipboard_meta
        WHERE content_hash = '\(escape(contentHash))' AND content_type <> 'blocked'
        ORDER BY captured_at DESC;
        """)
        return rows.compactMap { $0["id"] as? String }
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
                byteCount: row["byte_count"] as? Int ?? 0,
                contentHash: row["content_hash"] as? String ?? ""
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

    public func search(_ query: String, limit: Int = 25) throws -> String {
        try structuredSearch(query, limit: limit).map {
            "\(iso($0.capturedAt)) \($0.id) \($0.sourceApp)\n\($0.snippet)"
        }.joined(separator: "\n---\n")
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
            // A prune or a delete is this process writing to its own index;
            // re-stamping keeps the next capture on one cheap stat instead
            // of a full-database integrity check.
            Self.verifiedSchemas.record(indexURL.path, stamp: Self.fileStamp(atPath: indexURL.path))
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

    /// Runs one read query against the index and returns its rows.
    ///
    /// Column values come back as `Int` or `String`, which is what the old
    /// `sqlite3 -json` runner produced; an empty result is an empty array.
    /// The framing question that mode existed to answer — clipboard text
    /// can legally contain any in-band delimiter — no longer arises, because
    /// values are read straight out of SQLite and never serialised on the
    /// way here.
    func runSQLiteJSON(_ sql: String) throws -> [[String: Any]] {
        // Delegated to the reader that already runs queries in this process.
        // Spawning `/usr/bin/sqlite3` cost 67 ms of process creation per call
        // and returned nothing the C API does not — the same rows, with the
        // same Int-or-String typing, and without a subprocess CREATING the
        // database file as a side effect when the index is missing. Every
        // caller here reads: `schemaIsCurrent`, `userVersion`, `browse`,
        // `metaRows`, `distinctSourceApps` and `occurrenceIDs`. The first
        // four and `distinctSourceApps` reach an existing file (they check
        // for it, or run `ensureCurrentSchema` first); `occurrenceIDs`
        // deliberately does not, and its caller treats any throw as "fall
        // back to a reader scan", which a read-only open of a missing file
        // produces exactly as the old "no such table" failure did.
        //
        // No terms: `clipboard_matches` and `clipboard_snippet` exist for the
        // search path and appear in none of these statements. One statement
        // per call, which is all the reader prepares, and which it refuses to
        // exceed.
        //
        // One trade-off: a read-only connection cannot roll back a hot
        // journal left by a writer that died mid-transaction, where the CLI
        // opened read-write and recovered the file in passing. Such a read
        // fails until something opens the index for writing, which the next
        // capture or `ensureCurrentSchema` does — a window, not a loss.
        try ClipboardSQLiteSearch.rows(indexURL: indexURL, sql: sql, terms: [])
    }

    /// Executes a whole SQL script against the index, in this process.
    ///
    /// This is an executor swap and nothing else: the scripts, their
    /// escaping, and the two-layer lock discipline around them are
    /// unchanged, so the upsert, delete and search suites cover the new
    /// path without being rewritten. What it removes is a
    /// `Foundation.Process` spawn per capture, measured at 67 ms of the
    /// 70 ms an ingest took — the cost was creating a process, not SQLite,
    /// which does the same work here in about 9 ms.
    ///
    /// The journal mode stays DELETE. WAL saved roughly 1 ms per write and
    /// would cost a `-wal` and a `-shm` file sitting beside an index that
    /// the backup exporter and the alternate-index report both enumerate;
    /// a millisecond does not buy two new files in that set.
    ///
    /// A script that fails partway may leave its transaction open, and this
    /// connection is about to close: an explicit rollback makes the failure
    /// discard the partial write rather than leaving it to SQLite's own
    /// cleanup.
    private func runSQLite(input sql: String) throws {
        var database: OpaquePointer?
        let opened = sqlite3_open_v2(
            indexURL.path,
            &database,
            SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_NOMUTEX,
            nil
        )
        guard opened == SQLITE_OK, let database else {
            if let database {
                sqlite3_close(database)
            }
            throw ClipboardDerivedIndexError.sqliteFailed(opened)
        }
        defer { sqlite3_close(database) }
        // Matches the `PRAGMA busy_timeout` the scripts carry: a lock held
        // by another writer is waited out, not reported as a failure.
        sqlite3_busy_timeout(database, 2000)
        let result = sqlite3_exec(database, sql, nil, nil, nil)
        guard result == SQLITE_OK else {
            if sqlite3_get_autocommit(database) == 0 {
                sqlite3_exec(database, "ROLLBACK;", nil, nil, nil)
            }
            throw ClipboardDerivedIndexError.sqliteFailed(result)
        }
    }

    /// `PRAGMA quick_check` on a database file, in this process.
    ///
    /// Read-only: this runs against a rebuild's temporary file before it is
    /// promoted, and against the live index for the dashboard's verify
    /// button, and neither wants an open for writing. A damaged database
    /// answers with rows of error text where a healthy one answers a single
    /// "ok", so anything other than exactly that one row fails validation,
    /// as it did when the CLI printed the same rows.
    private func validateIndex(at url: URL) throws {
        // `undetermined` still fails here, and that is deliberate: this gates a
        // rebuild's temporary file before promotion, and promoting a file you
        // could not verify is worse than rebuilding again later.
        guard quickCheckOutcome(at: url) == .ok else {
            throw ClipboardDerivedIndexError.validationFailed
        }
    }

    func quickCheckOutcome(at url: URL) -> QuickCheckOutcome {
        var database: OpaquePointer?
        let opened = sqlite3_open_v2(url.path, &database, SQLITE_OPEN_READONLY, nil)
        guard opened == SQLITE_OK, let database else {
            if let database {
                sqlite3_close(database)
            }
            return Self.isContention(opened) ? .undetermined : .damaged
        }
        defer { sqlite3_close(database) }
        sqlite3_busy_timeout(database, Self.busyTimeoutMilliseconds)
        var statement: OpaquePointer?
        let prepared = sqlite3_prepare_v2(database, "PRAGMA quick_check;", -1, &statement, nil)
        guard prepared == SQLITE_OK, let statement else {
            return Self.isContention(prepared) ? .undetermined : .damaged
        }
        defer { sqlite3_finalize(statement) }
        var lines: [String] = []
        var step = sqlite3_step(statement)
        while step == SQLITE_ROW {
            guard let text = sqlite3_column_text(statement, 0) else { return .damaged }
            lines.append(String(cString: text).trimmingCharacters(in: .whitespacesAndNewlines))
            step = sqlite3_step(statement)
        }
        // THE TERMINATING CODE IS THE WHOLE FIX. The loop above ends identically
        // for DONE, BUSY, LOCKED and CORRUPT, so without reading `step` there is
        // nothing left to tell "healthy, and someone else is writing to it" from
        // "damaged". Getting that wrong costs a `forget`, a false
        // index_corrupt_detected row in a log whose job is to grade, and a full
        // rebuild of an index that was fine.
        if Self.isContention(step) { return .undetermined }
        guard step == SQLITE_DONE else { return .damaged }
        return lines == ["ok"] ? .ok : .damaged
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
