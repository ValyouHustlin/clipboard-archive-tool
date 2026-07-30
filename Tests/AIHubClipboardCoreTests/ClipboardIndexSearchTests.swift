import Foundation
import Testing
@testable import ClipboardArchiveCore

/// Slice 3 test plan: structured index search, schema v2 migration, read-time
/// suppression, and the by-id reader fetch. Synthetic data only, /tmp roots
/// only (expansion contract 10).
@Suite("Clipboard Index Search")
struct ClipboardIndexSearchTests {
    // MARK: - Helpers (synthetic data only, temp roots only)

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("clipboard-index-search-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private static let compactFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        return formatter
    }()

    /// A writer-shaped id whose embedded UTC day matches `capturedAt`, so
    /// `event(withID:)` resolves the correct day file.
    private func wellFormedID(for capturedAt: Date, suffix: String) -> String {
        "clip_\(Self.compactFormatter.string(from: capturedAt))_synthetic0000_\(suffix)"
    }

    private func makeEvent(
        id: String,
        capturedAt: Date,
        content: String,
        contentType: ClipboardContentType = .text,
        appName: String = "Synthetic Test",
        bundleID: String? = "test.synthetic",
        privacyLabel: PrivacyLabel = .privateLocal
    ) -> StoredClipboardEvent {
        StoredClipboardEvent(
            id: id,
            capturedAt: capturedAt,
            contentType: contentType,
            contentHash: "sha256:synthetic-\(id)",
            contentPreview: String(content.prefix(240)),
            contentInline: content,
            rawContentPath: nil,
            sourceApp: ClipboardSourceApp(name: appName, bundleIdentifier: bundleID),
            pasteboardTypes: ["public.utf8-plain-text"],
            byteCount: content.utf8.count,
            characterCount: content.count,
            lineCount: content.split(separator: "\n", omittingEmptySubsequences: false).count,
            privacyLabel: privacyLabel,
            allowedUse: privacyLabel == .doNotIndex ? [.doNotIndex] : [.localSearch, .localAnalysis],
            sensitivityFlags: [],
            uiVisibleUntil: capturedAt.addingTimeInterval(7 * 86_400)
        )
    }

    private func dayFileURL(for date: Date, archiveRoot: URL) -> URL {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy/MM/yyyy-MM-dd"
        return archiveRoot
            .appendingPathComponent("raw/\(formatter.string(from: date))_clipboard-events.ndjson")
    }

    private func appendEventLine(_ event: StoredClipboardEvent, archiveRoot: URL) throws {
        let url = dayFileURL(for: event.capturedAt, archiveRoot: archiveRoot)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        var data = try encoder.encode(event)
        data.append(0x0A)
        if FileManager.default.fileExists(atPath: url.path) {
            let handle = try FileHandle(forWritingTo: url)
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
            try handle.close()
        } else {
            try data.write(to: url)
        }
    }

    /// Test-only SQL helper for assertions and fixture manufacture. Uses
    /// argv deliberately — this is authored test SQL, never user content.
    @discardableResult
    private func runSQL(database: URL, sql: String) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        process.arguments = [database.path, sql]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0)
        return String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    private func fileIdentity(of url: URL) throws -> (inode: UInt64, modified: Date) {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        let inode = (attributes[.systemFileNumber] as? NSNumber)?.uint64Value ?? 0
        let modified = attributes[.modificationDate] as? Date ?? Date.distantPast
        return (inode, modified)
    }

    private let baseDate = ISO8601DateFormatter().date(from: "2026-06-10T12:00:00Z")!

    // MARK: - Hostile content round-trip

    @Test
    func testHostileContentRoundTripsExactly() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let indexURL = root.appendingPathComponent("index.sqlite")
        let index = ClipboardDerivedIndex(archiveRoot: root, indexURL: indexURL)

        let hostileBodies: [(id: String, content: String, token: String)] = [
            (
                "evt-injection",
                "Robert'); DROP TABLE clipboard_meta;-- injectiontoken",
                "injectiontoken"
            ),
            (
                "evt-backslash",
                #"C:\Users\test\path \" backslashtoken \\ end"#,
                "backslashtoken"
            ),
            (
                "evt-newline-tab",
                "line one\n\tline two newlinetoken\nline three",
                "newlinetoken"
            ),
            (
                "evt-unicode-nfc",
                "caf\u{00E9} r\u{00E9}sum\u{00E9} nfctoken \u{1F4CB}\u{2705}",
                "nfctoken"
            ),
            (
                "evt-unicode-nfd",
                "cafe\u{0301} re\u{0301}sume\u{0301} nfdtoken",
                "nfdtoken"
            ),
            (
                "evt-separators",
                "alpha\u{1F}beta\u{1E}gamma separatortoken end",
                "separatortoken"
            )
        ]

        for (offset, fixture) in hostileBodies.enumerated() {
            try appendEventLine(
                makeEvent(
                    id: fixture.id,
                    capturedAt: baseDate.addingTimeInterval(Double(offset) * 60),
                    content: fixture.content
                ),
                archiveRoot: root
            )
        }
        #expect(try index.rebuild() == hostileBodies.count)

        for fixture in hostileBodies {
            let results = try index.structuredSearch(fixture.token)
            #expect(results.count == 1, "expected one hit for \(fixture.token)")
            guard let result = results.first else {
                continue
            }
            #expect(result.id == fixture.id)
            #expect(result.sourceApp == "Synthetic Test")
            #expect(result.bundleID == "test.synthetic")
            #expect(result.contentType == "text")
            #expect(result.byteCount == fixture.content.utf8.count)
            #expect(result.snippet.contains(fixture.token))
        }

        // Raw 0x1F/0x1E bytes must survive JSON output framing intact.
        let separatorHit = try #require(try index.structuredSearch("separatortoken").first)
        #expect(separatorHit.snippet.contains("\u{1F}"))
        #expect(separatorHit.snippet.contains("\u{1E}"))
        #expect(separatorHit.snippet.contains("alpha\u{1F}beta\u{1E}gamma"))

        // Injection-shaped QUERY text must never change SQL structure.
        #expect(try index.structuredSearch("token'); DROP TABLE clipboard_meta;--").isEmpty)
        #expect(try index.structuredSearch("\" OR \" NEAR( * ^ -").isEmpty)
        #expect(try runSQL(database: indexURL, sql: "SELECT COUNT(*) FROM clipboard_meta;")
            == "\(hostileBodies.count)")

        // Exact capture timestamp round-trip (second precision).
        let injectionHit = try #require(try index.structuredSearch("injectiontoken").first)
        #expect(injectionHit.capturedAt == baseDate)
    }

    @Test
    func testLargeBodyEventRoundTripsThroughSearch() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let indexURL = root.appendingPathComponent("index.sqlite")
        let writer = ClipboardArchiveWriter(archiveRoot: root, inlineContentLimitBytes: 32)
        let content = "large body fixture largebodytoken " + String(repeating: "filler ", count: 64)
        let event = try writer.archiveAllowedCapture(ClipboardCapture(
            capturedAt: baseDate,
            content: content,
            sourceApp: ClipboardSourceApp(name: "Synthetic Test", bundleIdentifier: "test.synthetic"),
            pasteboardTypes: ["public.utf8-plain-text"]
        ))
        #expect(event.rawContentPath != nil)

        let index = ClipboardDerivedIndex(archiveRoot: root, indexURL: indexURL)
        #expect(try index.rebuild() == 1)
        let results = try index.structuredSearch("largebodytoken")
        #expect(results.map(\.id) == [event.id])
        #expect(results.first?.byteCount == content.utf8.count)
    }

    @Test
    func testEmptyResultSetIsEmptyArrayNotError() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let indexURL = root.appendingPathComponent("index.sqlite")
        try appendEventLine(
            makeEvent(id: "evt-present", capturedAt: baseDate, content: "present fixture"),
            archiveRoot: root
        )
        let index = ClipboardDerivedIndex(archiveRoot: root, indexURL: indexURL)
        #expect(try index.rebuild() == 1)
        #expect(try index.structuredSearch("no-such-token-anywhere").isEmpty)
        #expect(try index.browse(
            filters: ClipboardIndexSearchFilters(bundleID: "no.such.bundle")
        ).isEmpty)
    }

    @Test
    func testCorruptIndexSurfacesTypedError() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let indexURL = root.appendingPathComponent("index.sqlite")
        // A database stamped v2 but missing the FTS table: schema check
        // passes, the query itself fails → typed sqliteFailed error.
        try runSQL(database: indexURL, sql: "PRAGMA user_version=2; CREATE TABLE clipboard_meta(id TEXT PRIMARY KEY, captured_at TEXT, source_app TEXT, bundle_id TEXT, content_type TEXT, byte_count INTEGER, raw_content_path TEXT, content_hash TEXT, preview TEXT);")
        let index = ClipboardDerivedIndex(archiveRoot: root, indexURL: indexURL)
        #expect(throws: ClipboardDerivedIndexError.self) {
            _ = try index.structuredSearch("anything")
        }
    }

    @Test
    func testUndecodableSQLiteOutputIsMalformedOutputError() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let indexURL = root.appendingPathComponent("index.sqlite")
        try Data().write(to: indexURL)

        // Stub sqlite3: answers the schema-version probe with valid JSON,
        // then emits garbage for the actual query.
        let stubURL = root.appendingPathComponent("sqlite3-stub.sh")
        let stub = """
        #!/bin/sh
        SQL=$(cat)
        case "$SQL" in
          *pragma_user_version*) printf '[{"user_version":2}]' ;;
          *) printf 'definitely not json' ;;
        esac
        """
        try Data(stub.utf8).write(to: stubURL)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: Int16(0o700))],
            ofItemAtPath: stubURL.path
        )

        let index = ClipboardDerivedIndex(
            archiveRoot: root,
            indexURL: indexURL,
            sqliteExecutableURL: stubURL
        )
        #expect(throws: ClipboardDerivedIndexError.malformedOutput) {
            _ = try index.structuredSearch("anything")
        }
    }

    // MARK: - Filter correctness

    private func seedFilterFixtures(root: URL, indexURL: URL) throws -> ClipboardDerivedIndex {
        let fixtures: [(id: String, offset: TimeInterval, app: String, bundle: String, type: ClipboardContentType, content: String)] = [
            ("evt-notes-old", 0, "Notes", "com.apple.Notes", .text, "shared filtertoken notes old"),
            ("evt-safari-mid", 3_600, "Safari", "com.apple.Safari", .url, "https://example.com/ shared filtertoken safari"),
            ("evt-xcode-new", 7_200, "Xcode", "com.apple.dt.Xcode", .code, "func shared() { filtertoken } struct X {}"),
            ("evt-notes-new", 10_800, "Notes", "com.apple.Notes", .text, "shared filtertoken notes new")
        ]
        for fixture in fixtures {
            try appendEventLine(
                makeEvent(
                    id: fixture.id,
                    capturedAt: baseDate.addingTimeInterval(fixture.offset),
                    content: fixture.content,
                    contentType: fixture.type,
                    appName: fixture.app,
                    bundleID: fixture.bundle
                ),
                archiveRoot: root
            )
        }
        let index = ClipboardDerivedIndex(archiveRoot: root, indexURL: indexURL)
        #expect(try index.rebuild() == fixtures.count)
        return index
    }

    @Test
    func testDateBoundsAreInclusiveAtExactSecond() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let index = try seedFilterFixtures(root: root, indexURL: root.appendingPathComponent("index.sqlite"))
        let safariCapturedAt = baseDate.addingTimeInterval(3_600)

        // since exactly at capture time: included.
        var filters = ClipboardIndexSearchFilters(since: safariCapturedAt)
        #expect(try index.structuredSearch("filtertoken", filters: filters).map(\.id)
            == ["evt-notes-new", "evt-xcode-new", "evt-safari-mid"])
        // since one second later: excluded.
        filters.since = safariCapturedAt.addingTimeInterval(1)
        #expect(try index.structuredSearch("filtertoken", filters: filters).map(\.id)
            == ["evt-notes-new", "evt-xcode-new"])
        // until exactly at capture time: included.
        filters = ClipboardIndexSearchFilters(until: safariCapturedAt)
        #expect(try index.structuredSearch("filtertoken", filters: filters).map(\.id)
            == ["evt-safari-mid", "evt-notes-old"])
        // until one second earlier: excluded.
        filters.until = safariCapturedAt.addingTimeInterval(-1)
        #expect(try index.structuredSearch("filtertoken", filters: filters).map(\.id)
            == ["evt-notes-old"])
    }

    @Test
    func testAppTypeAndCombinedFiltersAndOrderingAndLimit() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let index = try seedFilterFixtures(root: root, indexURL: root.appendingPathComponent("index.sqlite"))

        // Newest-first ordering with no filters.
        #expect(try index.structuredSearch("filtertoken").map(\.id)
            == ["evt-notes-new", "evt-xcode-new", "evt-safari-mid", "evt-notes-old"])

        // Bundle id filter.
        #expect(try index.structuredSearch(
            "filtertoken",
            filters: ClipboardIndexSearchFilters(bundleID: "com.apple.Safari")
        ).map(\.id) == ["evt-safari-mid"])

        // Source app name filter.
        #expect(try index.structuredSearch(
            "filtertoken",
            filters: ClipboardIndexSearchFilters(sourceAppName: "Notes")
        ).map(\.id) == ["evt-notes-new", "evt-notes-old"])

        // Content type filter.
        #expect(try index.structuredSearch(
            "filtertoken",
            filters: ClipboardIndexSearchFilters(contentType: "code")
        ).map(\.id) == ["evt-xcode-new"])

        // Combined: app + date window excludes the newer Notes event.
        #expect(try index.structuredSearch(
            "filtertoken",
            filters: ClipboardIndexSearchFilters(
                until: baseDate.addingTimeInterval(3_599),
                sourceAppName: "Notes"
            )
        ).map(\.id) == ["evt-notes-old"])

        // Limit bounds: 1...500 clamp and truncation keeps newest.
        #expect(try index.structuredSearch("filtertoken", limit: 2).map(\.id)
            == ["evt-notes-new", "evt-xcode-new"])
        #expect(try index.structuredSearch("filtertoken", limit: 0).count == 1)
        #expect(try index.structuredSearch("filtertoken", limit: 100_000).count == 4)
    }

    @Test
    func testBrowseModeFiltersAndPreviewSnippet() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let index = try seedFilterFixtures(root: root, indexURL: root.appendingPathComponent("index.sqlite"))

        // Browse with no query returns everything newest-first, snippet
        // backed by the stored preview column.
        let all = try index.browse()
        #expect(all.map(\.id)
            == ["evt-notes-new", "evt-xcode-new", "evt-safari-mid", "evt-notes-old"])
        #expect(all.last?.snippet == "shared filtertoken notes old")

        // Browse filters mirror search filters.
        #expect(try index.browse(
            filters: ClipboardIndexSearchFilters(sourceAppName: "Safari")
        ).map(\.id) == ["evt-safari-mid"])
        #expect(try index.browse(
            filters: ClipboardIndexSearchFilters(
                since: baseDate.addingTimeInterval(7_200),
                contentType: "text"
            )
        ).map(\.id) == ["evt-notes-new"])
        #expect(try index.browse(limit: 3).count == 3)

        // An all-whitespace query is a browse, not an FTS error.
        #expect(try index.structuredSearch("   \n\t ").map(\.id) == all.map(\.id))

        // distinctSourceApps feeds the UI popup.
        #expect(try index.distinctSourceApps() == ["Notes", "Safari", "Xcode"])
    }

    // MARK: - Schema versioning (v0 → v2)

    private static let legacyV0SchemaSQL = """
    CREATE VIRTUAL TABLE IF NOT EXISTS clipboard_fts USING fts5(id UNINDEXED, captured_at UNINDEXED, source_app, content_type, preview, body);
    CREATE TABLE IF NOT EXISTS clipboard_meta(id TEXT PRIMARY KEY, captured_at TEXT, source_app TEXT, bundle_id TEXT, content_type TEXT, byte_count INTEGER, raw_content_path TEXT);
    """

    @Test
    func testLegacyV0IndexIsRebuiltToV2OnFirstStructuredSearch() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let indexURL = root.appendingPathComponent("index.sqlite")

        try appendEventLine(
            makeEvent(id: "evt-migrate", capturedAt: baseDate, content: "migration migratetoken fixture"),
            archiveRoot: root
        )
        // Hand-built legacy index exactly as a pre-versioning binary wrote
        // it: old columns, stale content, user_version 0.
        try runSQL(database: indexURL, sql: Self.legacyV0SchemaSQL + """
        INSERT INTO clipboard_fts(id,captured_at,source_app,content_type,preview,body) VALUES('evt-stale','2026-01-01T00:00:00Z','Old','text','stale','stale legacy row');
        INSERT INTO clipboard_meta(id,captured_at,source_app,bundle_id,content_type,byte_count,raw_content_path) VALUES('evt-stale','2026-01-01T00:00:00Z','Old','old.bundle','text',5,'');
        """)
        #expect(try runSQL(database: indexURL, sql: "PRAGMA user_version;") == "0")

        let index = ClipboardDerivedIndex(archiveRoot: root, indexURL: indexURL)
        let results = try index.structuredSearch("migratetoken")
        #expect(results.map(\.id) == ["evt-migrate"])

        // Rebuilt: version stamped, new columns exist and are populated,
        // stale legacy rows replaced by archive truth.
        #expect(try runSQL(database: indexURL, sql: "PRAGMA user_version;") == "2")
        let columns = try runSQL(database: indexURL, sql: "SELECT name FROM pragma_table_info('clipboard_meta') ORDER BY name;")
        #expect(columns.contains("content_hash"))
        #expect(columns.contains("preview"))
        #expect(try runSQL(database: indexURL, sql: "SELECT content_hash FROM clipboard_meta WHERE id='evt-migrate';")
            == "sha256:synthetic-evt-migrate")
        #expect(try runSQL(database: indexURL, sql: "SELECT COUNT(*) FROM clipboard_meta WHERE id='evt-stale';") == "0")
        // The new captured_at / content_hash indexes exist.
        let indexes = try runSQL(database: indexURL, sql: "SELECT name FROM sqlite_master WHERE type='index' ORDER BY name;")
        #expect(indexes.contains("clipboard_meta_captured_at_idx"))
        #expect(indexes.contains("clipboard_meta_content_hash_idx"))
    }

    @Test
    func testMissingIndexFileIsBuiltAndSecondEnsureIsANoOp() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let indexURL = root.appendingPathComponent("index.sqlite")
        try appendEventLine(
            makeEvent(id: "evt-build", capturedAt: baseDate, content: "buildtoken fixture"),
            archiveRoot: root
        )

        let index = ClipboardDerivedIndex(archiveRoot: root, indexURL: indexURL)
        #expect(!FileManager.default.fileExists(atPath: indexURL.path))
        #expect(try index.ensureCurrentSchema() == true)
        #expect(FileManager.default.fileExists(atPath: indexURL.path))
        #expect(try runSQL(database: indexURL, sql: "PRAGMA user_version;") == "2")

        // Second ensure must be a pure read: same inode, same mtime.
        let before = try fileIdentity(of: indexURL)
        #expect(try index.ensureCurrentSchema() == false)
        let after = try fileIdentity(of: indexURL)
        #expect(before.inode == after.inode)
        #expect(before.modified == after.modified)
    }

    @Test
    func testFailedRebuildPreservesPriorIndexBytes() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let indexURL = root.appendingPathComponent("index.sqlite")
        try appendEventLine(
            makeEvent(id: "evt-preserve", capturedAt: baseDate, content: "preservetoken fixture"),
            archiveRoot: root
        )
        // Valid legacy index that a failed rebuild must leave untouched.
        try runSQL(database: indexURL, sql: Self.legacyV0SchemaSQL)
        let bytesBefore = try Data(contentsOf: indexURL)

        let broken = ClipboardDerivedIndex(
            archiveRoot: root,
            indexURL: indexURL,
            sqliteExecutableURL: URL(fileURLWithPath: "/usr/bin/false")
        )
        #expect(throws: ClipboardDerivedIndexError.self) {
            _ = try broken.structuredSearch("preservetoken")
        }
        #expect(try Data(contentsOf: indexURL) == bytesBefore)
        #expect(try runSQL(database: indexURL, sql: "PRAGMA user_version;") == "0")
    }

    // MARK: - Suppression parity and drift (contract 6)

    @Test
    func testLedgerDriftIsExcludedFromSearchBrowseAndByIDFetch() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let indexURL = root.appendingPathComponent("index.sqlite")
        let keptID = wellFormedID(for: baseDate, suffix: "aaaa0001")
        let driftedID = wellFormedID(for: baseDate.addingTimeInterval(60), suffix: "aaaa0002")
        try appendEventLine(
            makeEvent(id: keptID, capturedAt: baseDate, content: "drifttoken kept"),
            archiveRoot: root
        )
        try appendEventLine(
            makeEvent(id: driftedID, capturedAt: baseDate.addingTimeInterval(60), content: "drifttoken drifted"),
            archiveRoot: root
        )
        let index = ClipboardDerivedIndex(archiveRoot: root, indexURL: indexURL)
        #expect(try index.rebuild() == 2)

        // Manufacture drift: ledger append WITHOUT an index delete. The
        // index still physically holds the row.
        try ClipboardDeletionLedger(archiveRoot: root)
            .recordDeletion(eventID: driftedID, reason: "drift-test")
        #expect(try runSQL(database: indexURL, sql: "SELECT COUNT(*) FROM clipboard_meta WHERE id='\(driftedID)';") == "1")

        // Read-time suppression hides it from every structured surface.
        #expect(try index.structuredSearch("drifttoken").map(\.id) == [keptID])
        #expect(try index.browse().map(\.id) == [keptID])
        // And the by-id fetch refuses to resurrect it.
        let reader = ClipboardArchiveReader(archiveRoot: root)
        #expect(try reader.event(withID: driftedID) == nil)
        #expect(try reader.event(withID: keptID)?.id == keptID)
    }

    @Test
    func testDoNotIndexEventIsExcludedEverywhere() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let indexURL = root.appendingPathComponent("index.sqlite")
        let visibleID = wellFormedID(for: baseDate, suffix: "bbbb0001")
        let hiddenID = wellFormedID(for: baseDate.addingTimeInterval(60), suffix: "bbbb0002")
        try appendEventLine(
            makeEvent(id: visibleID, capturedAt: baseDate, content: "dnitoken visible"),
            archiveRoot: root
        )
        try appendEventLine(
            makeEvent(
                id: hiddenID,
                capturedAt: baseDate.addingTimeInterval(60),
                content: "dnitoken hidden",
                privacyLabel: .doNotIndex
            ),
            archiveRoot: root
        )
        let index = ClipboardDerivedIndex(archiveRoot: root, indexURL: indexURL)
        #expect(try index.rebuild() == 1)
        #expect(try index.structuredSearch("dnitoken").map(\.id) == [visibleID])
        #expect(try index.browse().map(\.id) == [visibleID])
        #expect(try ClipboardArchiveReader(archiveRoot: root).event(withID: hiddenID) == nil)
    }

    @Test
    func testSyntheticBlockedRowIsExcludedBySQLGuard() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let indexURL = root.appendingPathComponent("index.sqlite")
        try appendEventLine(
            makeEvent(id: "evt-normal", capturedAt: baseDate, content: "guardtoken normal"),
            archiveRoot: root
        )
        let index = ClipboardDerivedIndex(archiveRoot: root, indexURL: indexURL)
        #expect(try index.rebuild() == 1)

        // Foreign 'blocked' row injected with raw SQL — the writers never
        // produce one, so only the SQL guard can keep it out of results.
        try runSQL(database: indexURL, sql: """
        INSERT INTO clipboard_fts(id,captured_at,source_app,content_type,preview,body) VALUES('evt-blocked','2026-06-10T13:00:00Z','Rogue','blocked','guardtoken blocked','guardtoken blocked body');
        INSERT INTO clipboard_meta(id,captured_at,source_app,bundle_id,content_type,byte_count,raw_content_path,content_hash,preview) VALUES('evt-blocked','2026-06-10T13:00:00Z','Rogue','rogue.bundle','blocked',10,'','sha256:blocked','guardtoken blocked');
        """)

        #expect(try index.structuredSearch("guardtoken").map(\.id) == ["evt-normal"])
        #expect(try index.browse().map(\.id) == ["evt-normal"])
        #expect(!(try index.distinctSourceApps().contains("Rogue")))
    }

    // MARK: - Reader by-id fetch

    @Test
    func testEventWithIDRoundTripsWriterEventsIncludingLargeBody() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let writer = ClipboardArchiveWriter(archiveRoot: root, inlineContentLimitBytes: 32)
        let reader = ClipboardArchiveReader(archiveRoot: root)

        let smallContent = "small by-id fixture"
        let largeContent = "large by-id fixture " + String(repeating: "padding ", count: 32)
        let small = try writer.archiveAllowedCapture(ClipboardCapture(
            capturedAt: baseDate,
            content: smallContent,
            sourceApp: ClipboardSourceApp(name: "Synthetic Test", bundleIdentifier: "test.synthetic")
        ))
        let large = try writer.archiveAllowedCapture(ClipboardCapture(
            capturedAt: baseDate.addingTimeInterval(60),
            content: largeContent,
            sourceApp: ClipboardSourceApp(name: "Synthetic Test", bundleIdentifier: "test.synthetic")
        ))

        let fetchedSmall = try #require(try reader.event(withID: small.id))
        #expect(fetchedSmall == small)
        #expect(try reader.content(for: fetchedSmall) == smallContent)

        let fetchedLarge = try #require(try reader.event(withID: large.id))
        #expect(fetchedLarge == large)
        #expect(fetchedLarge.rawContentPath != nil)
        #expect(try reader.content(for: fetchedLarge) == largeContent)
    }

    @Test
    func testEventWithIDRejectsMalformedAndTraversalShapedIDs() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try appendEventLine(
            makeEvent(
                id: wellFormedID(for: baseDate, suffix: "cccc0001"),
                capturedAt: baseDate,
                content: "by-id guard fixture"
            ),
            archiveRoot: root
        )
        let reader = ClipboardArchiveReader(archiveRoot: root)

        let malformedIDs = [
            "",
            "clip_",
            "clip_short",
            "not_a_clip_id",
            "clip_2026061a_badday",
            "clip_../../../../etc/passwd",
            "clip_..%2F..%2Fetc",
            "clip_żżżżżżżż_unicode",
            "CLIP_20260610T120000Z_wrongcase"
        ]
        for malformed in malformedIDs {
            #expect(try reader.event(withID: malformed) == nil, "expected nil for \(malformed)")
        }

        // Well-formed shape, but no day file for that date.
        #expect(try reader.event(
            withID: "clip_19990101T000000Z_synthetic0000_dddd0001"
        ) == nil)
        // Well-formed shape, day file exists, id absent.
        #expect(try reader.event(
            withID: wellFormedID(for: baseDate, suffix: "ffff9999")
        ) == nil)
    }
}
