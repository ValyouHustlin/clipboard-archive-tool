import Foundation
import Testing
@testable import ClipboardArchiveCore

/// Slice 4 duplicate grouping (contract 2: content identity) — the pure
/// grouping engine plus the meta-only index query that feeds All History
/// grouping. Synthetic fixtures under temp roots only (contract 10).
@Suite("Duplicate Grouping")
struct DuplicateGroupingTests {
    private let formatter = ISO8601DateFormatter()

    private func makeEvent(
        id: String,
        capturedAt: Date,
        content: String,
        contentHash: String,
        contentType: ClipboardContentType = .text,
        privacyLabel: PrivacyLabel = .privateLocal
    ) -> StoredClipboardEvent {
        StoredClipboardEvent(
            id: id,
            capturedAt: capturedAt,
            contentType: contentType,
            contentHash: contentHash,
            contentPreview: String(content.prefix(240)),
            contentInline: content,
            rawContentPath: nil,
            sourceApp: ClipboardSourceApp(name: "Synthetic Test", bundleIdentifier: "test.synthetic"),
            pasteboardTypes: ["public.utf8-plain-text"],
            byteCount: content.utf8.count,
            characterCount: content.count,
            lineCount: 1,
            privacyLabel: privacyLabel,
            allowedUse: privacyLabel == .doNotIndex ? [.doNotIndex] : [.localSearch, .localAnalysis],
            sensitivityFlags: [],
            uiVisibleUntil: capturedAt.addingTimeInterval(7 * 86_400)
        )
    }

    private func date(_ iso: String) -> Date {
        formatter.date(from: iso)!
    }

    // MARK: - Pure grouping engine

    @Test
    func testGroupingCountsDatesRepresentativeAndOrdering() throws {
        // Newest-first input, hashes interleaved:
        // b3(hashB) a2(hashA) b2 c(single) b1 a1
        let b3 = makeEvent(id: "b3", capturedAt: date("2026-07-20T12:00:00Z"), content: "dup B", contentHash: "sha256:B")
        let a2 = makeEvent(id: "a2", capturedAt: date("2026-07-20T11:00:00Z"), content: "dup A", contentHash: "sha256:A")
        let b2 = makeEvent(id: "b2", capturedAt: date("2026-07-20T10:00:00Z"), content: "dup B", contentHash: "sha256:B")
        let c1 = makeEvent(id: "c1", capturedAt: date("2026-07-20T09:00:00Z"), content: "solo C", contentHash: "sha256:C")
        let b1 = makeEvent(id: "b1", capturedAt: date("2026-07-12T08:00:00Z"), content: "dup B", contentHash: "sha256:B")
        let a1 = makeEvent(id: "a1", capturedAt: date("2026-07-11T07:00:00Z"), content: "dup A", contentHash: "sha256:A")

        let rows = ClipboardDuplicateGrouping.rows(grouping: [b3, a2, b2, c1, b1, a1])
        #expect(rows.count == 3)

        guard case let .group(groupB) = rows[0] else {
            Issue.record("expected group B first")
            return
        }
        #expect(groupB.contentHash == "sha256:B")
        #expect(groupB.count == 3)
        #expect(groupB.newest.id == "b3")
        #expect(groupB.occurrences.map(\.id) == ["b3", "b2", "b1"])
        #expect(groupB.firstCapturedAt == b1.capturedAt)
        #expect(groupB.lastCapturedAt == b3.capturedAt)

        guard case let .group(groupA) = rows[1] else {
            Issue.record("expected group A second")
            return
        }
        #expect(groupA.count == 2)
        #expect(groupA.newest.id == "a2")
        #expect(groupA.firstCapturedAt == a1.capturedAt)
        #expect(groupA.lastCapturedAt == a2.capturedAt)

        guard case let .single(single) = rows[2] else {
            Issue.record("expected single C last")
            return
        }
        #expect(single.id == "c1")
    }

    @Test
    func testEmptyContentHashNeverGroups() throws {
        // Rows indexed by an older binary can carry an empty hash; they must
        // stay individual rows instead of forming one bogus mega-group.
        let first = ClipboardIndexSearchResult(
            id: "old-1", capturedAt: date("2026-07-20T12:00:00Z"),
            sourceApp: "Notes", bundleID: nil, contentType: "text",
            snippet: "one", byteCount: 3, contentHash: ""
        )
        let second = ClipboardIndexSearchResult(
            id: "old-2", capturedAt: date("2026-07-20T11:00:00Z"),
            sourceApp: "Notes", bundleID: nil, contentType: "text",
            snippet: "two", byteCount: 3, contentHash: ""
        )
        let rows = ClipboardDuplicateGrouping.rows(grouping: [first, second])
        #expect(rows.count == 2)
        for row in rows {
            guard case .single = row else {
                Issue.record("empty-hash rows must never group")
                return
            }
        }
    }

    @Test
    func testSingleOccurrenceHashStaysASingleRow() throws {
        let only = makeEvent(
            id: "solo",
            capturedAt: date("2026-07-20T12:00:00Z"),
            content: "solo",
            contentHash: "sha256:solo"
        )
        let rows = ClipboardDuplicateGrouping.rows(grouping: [only])
        #expect(rows.count == 1)
        guard case let .single(item) = rows[0] else {
            Issue.record("expected a single row")
            return
        }
        #expect(item.id == "solo")
    }

    @Test
    func testFilterRunsBeforeGroupingSoCountsAreHonest() throws {
        // Three occurrences of the same hash, but one is a URL. The
        // existing predicate (type filter) runs FIRST; grouping then only
        // counts the survivors — the design's composition order.
        let textNew = makeEvent(id: "t2", capturedAt: date("2026-07-20T12:00:00Z"), content: "same", contentHash: "sha256:mixed")
        let urlMiddle = makeEvent(id: "u1", capturedAt: date("2026-07-20T11:00:00Z"), content: "same", contentHash: "sha256:mixed", contentType: .url)
        let textOld = makeEvent(id: "t1", capturedAt: date("2026-07-20T10:00:00Z"), content: "same", contentHash: "sha256:mixed")

        let filtered = [textNew, urlMiddle, textOld].filter { $0.contentType == .text }
        let rows = ClipboardDuplicateGrouping.rows(grouping: filtered)
        #expect(rows.count == 1)
        guard case let .group(group) = rows[0] else {
            Issue.record("expected one group of the two text survivors")
            return
        }
        #expect(group.count == 2)
        #expect(group.occurrences.map(\.id) == ["t2", "t1"])
    }

    // MARK: - metaRows (index-backed grouping source)

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("clipboard-grouping-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func appendEventLine(_ event: StoredClipboardEvent, archiveRoot: URL) throws {
        let dayFormatter = DateFormatter()
        dayFormatter.calendar = Calendar(identifier: .gregorian)
        dayFormatter.locale = Locale(identifier: "en_US_POSIX")
        dayFormatter.timeZone = TimeZone(secondsFromGMT: 0)
        dayFormatter.dateFormat = "yyyy/MM/yyyy-MM-dd"
        let url = archiveRoot
            .appendingPathComponent("raw/\(dayFormatter.string(from: event.capturedAt))_clipboard-events.ndjson")
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

    @Test
    func testMetaRowsCarryContentHashExcludeDriftAndRespectLimit() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let indexURL = root.appendingPathComponent("index.sqlite")

        var events: [StoredClipboardEvent] = []
        for slot in 0..<5 {
            let event = makeEvent(
                id: "evt-meta-\(slot)",
                capturedAt: date("2026-07-20T08:00:00Z").addingTimeInterval(Double(slot) * 60),
                content: "synthetic meta rows fixture \(slot)",
                contentHash: slot < 2 ? "sha256:meta-dup" : "sha256:meta-\(slot)"
            )
            events.append(event)
            try appendEventLine(event, archiveRoot: root)
        }
        let index = ClipboardDerivedIndex(archiveRoot: root, indexURL: indexURL)
        #expect(try index.rebuild() == 5)

        // Manufacture ledger drift AFTER the rebuild: the index still holds
        // the row; only read-time suppression can keep it out.
        try ClipboardDeletionLedger(archiveRoot: root)
            .recordDeletion(eventID: "evt-meta-4", reason: "test-drift")

        let rows = try index.metaRows()
        #expect(rows.map(\.id) == ["evt-meta-3", "evt-meta-2", "evt-meta-1", "evt-meta-0"])
        #expect(rows.allSatisfy { !$0.contentHash.isEmpty })
        #expect(rows.filter { $0.contentHash == "sha256:meta-dup" }.count == 2)

        // The grouped pipeline: metaRows → suppression (already applied) →
        // Swift grouping.
        let grouped = ClipboardDuplicateGrouping.rows(grouping: rows)
        #expect(grouped.count == 3)
        guard case let .group(group) = grouped[2] else {
            Issue.record("expected the duplicate pair to group")
            return
        }
        #expect(group.count == 2)

        // Limit is respected and hard-capped. LIMIT applies BEFORE the
        // read-time suppression post-filter, so the drifted newest row
        // (evt-meta-4) consumes a slot and the result under-fills — the
        // documented, accepted behavior (drift heals on the next rebuild).
        let limited = try index.metaRows(limit: 2)
        #expect(limited.map(\.id) == ["evt-meta-3"])
        let limitedThree = try index.metaRows(limit: 3)
        #expect(limitedThree.map(\.id) == ["evt-meta-3", "evt-meta-2"])
        #expect(ClipboardDerivedIndex.metaRowsMaximumLimit == 5_000)
    }

    @Test
    func testMetaRowsExcludeBlockedRows() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let indexURL = root.appendingPathComponent("index.sqlite")

        try appendEventLine(
            makeEvent(
                id: "evt-ok",
                capturedAt: date("2026-07-20T08:00:00Z"),
                content: "synthetic allowed row",
                contentHash: "sha256:ok"
            ),
            archiveRoot: root
        )
        let index = ClipboardDerivedIndex(archiveRoot: root, indexURL: indexURL)
        #expect(try index.rebuild() == 1)

        // Foreign blocked-type row injected straight into the index
        // (defense in depth — writers never index blocked events).
        let insert = """
        INSERT INTO clipboard_meta(id,captured_at,source_app,bundle_id,content_type,byte_count,raw_content_path,content_hash,preview)
        VALUES('evt-blocked','2026-07-20T09:00:00Z','X','','blocked',1,'','sha256:blocked','x');
        """
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        process.arguments = [indexURL.path, insert]
        try process.run()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0)

        let rows = try index.metaRows()
        #expect(rows.map(\.id) == ["evt-ok"])
    }

    @Test
    func testStructuredSearchAndBrowseIncludeContentHash() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let indexURL = root.appendingPathComponent("index.sqlite")

        try appendEventLine(
            makeEvent(
                id: "evt-hash-search",
                capturedAt: date("2026-07-20T08:00:00Z"),
                content: "synthetic hashable searchterm fixture",
                contentHash: "sha256:searchable"
            ),
            archiveRoot: root
        )
        let index = ClipboardDerivedIndex(archiveRoot: root, indexURL: indexURL)
        #expect(try index.rebuild() == 1)

        let searchResults = try index.structuredSearch("searchterm")
        #expect(searchResults.count == 1)
        #expect(searchResults.first?.contentHash == "sha256:searchable")

        let browseResults = try index.browse()
        #expect(browseResults.first?.contentHash == "sha256:searchable")
    }
}
