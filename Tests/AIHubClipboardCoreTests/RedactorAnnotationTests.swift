import Foundation
import Testing
@testable import ClipboardArchiveCore

/// Slice 4 last-occurrence annotation cleanup in the redactor (contract 5)
/// plus the occurrence resolver's stale-index and index-absent behavior.
/// Append-only extension — new file, synthetic fixtures under temp roots
/// only (contract 10).
@Suite("Redactor Annotation Cleanup")
struct RedactorAnnotationTests {
    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("clipboard-redactor-annotation-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func makeEvent(
        id: String,
        capturedAt: Date,
        content: String,
        contentHash: String
    ) -> StoredClipboardEvent {
        StoredClipboardEvent(
            id: id,
            capturedAt: capturedAt,
            contentType: .text,
            contentHash: contentHash,
            contentPreview: String(content.prefix(240)),
            contentInline: content,
            rawContentPath: nil,
            sourceApp: ClipboardSourceApp(name: "Synthetic Test", bundleIdentifier: "test.synthetic"),
            pasteboardTypes: ["public.utf8-plain-text"],
            byteCount: content.utf8.count,
            characterCount: content.count,
            lineCount: 1,
            privacyLabel: .privateLocal,
            allowedUse: [.localSearch, .localAnalysis],
            sensitivityFlags: [],
            uiVisibleUntil: capturedAt.addingTimeInterval(7 * 86_400)
        )
    }

    private func appendEventLine(_ event: StoredClipboardEvent, archiveRoot: URL) throws {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy/MM/yyyy-MM-dd"
        let url = archiveRoot
            .appendingPathComponent("raw/\(formatter.string(from: event.capturedAt))_clipboard-events.ndjson")
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

    private let sharedHash = "sha256:shared-redaction-fixture"

    /// Two occurrences of the same content on one day, ids in the
    /// `clip_<UTC day>` shape so the reader's by-id fetch works.
    private func seedTwoOccurrences(archiveRoot: URL) throws -> (older: StoredClipboardEvent, newer: StoredClipboardEvent) {
        let formatter = ISO8601DateFormatter()
        let older = makeEvent(
            id: "clip_20260720T090000Z_sharedfixtur_aa11bb22",
            capturedAt: formatter.date(from: "2026-07-20T09:00:00Z")!,
            content: "synthetic shared redaction fixture",
            contentHash: sharedHash
        )
        let newer = makeEvent(
            id: "clip_20260720T100000Z_sharedfixtur_cc33dd44",
            capturedAt: formatter.date(from: "2026-07-20T10:00:00Z")!,
            content: "synthetic shared redaction fixture",
            contentHash: sharedHash
        )
        try appendEventLine(older, archiveRoot: archiveRoot)
        try appendEventLine(newer, archiveRoot: archiveRoot)
        return (older, newer)
    }

    // MARK: - Occurrence resolver ordering

    @Test
    func testOccurrenceIDsComeBackNewestFirstFromIndex() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let indexURL = root.appendingPathComponent("index.sqlite")
        let fixtures = try seedTwoOccurrences(archiveRoot: root)
        _ = try ClipboardDerivedIndex(archiveRoot: root, indexURL: indexURL).rebuild()

        let ids = try ClipboardDerivedIndex(archiveRoot: root, indexURL: indexURL)
            .occurrenceIDs(contentHash: sharedHash)
        #expect(ids == [fixtures.newer.id, fixtures.older.id])

        let resolved = try ClipboardOccurrenceResolver(archiveRoot: root, indexURL: indexURL)
            .liveOccurrenceIDs(contentHash: sharedHash)
        #expect(resolved == [fixtures.newer.id, fixtures.older.id])
    }

    // MARK: - Keep annotation while occurrences remain

    @Test
    func testRedactingOneOfTwoOccurrencesKeepsAnnotation() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let indexURL = root.appendingPathComponent("index.sqlite")
        let fixtures = try seedTwoOccurrences(archiveRoot: root)
        _ = try ClipboardDerivedIndex(archiveRoot: root, indexURL: indexURL).rebuild()

        let store = ClipboardAnnotationsStore(archiveRoot: root)
        try store.setPinned(true, forContentHash: sharedHash)
        try store.setTags(["shared"], forContentHash: sharedHash)

        let result = try ClipboardArchiveRedactor(archiveRoot: root, indexURL: indexURL)
            .redact(eventID: fixtures.older.id)

        #expect(result.removedAnnotationContentHash == nil)
        let record = try #require(store.annotation(for: sharedHash))
        #expect(record.pinned)
        #expect(record.tags == ["shared"])
    }

    // MARK: - Last occurrence removes annotation + collection membership

    @Test
    func testRedactingLastOccurrenceRemovesAnnotationAndMembership() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let indexURL = root.appendingPathComponent("index.sqlite")
        let fixtures = try seedTwoOccurrences(archiveRoot: root)
        _ = try ClipboardDerivedIndex(archiveRoot: root, indexURL: indexURL).rebuild()

        let store = ClipboardAnnotationsStore(archiveRoot: root)
        try store.setPinned(true, forContentHash: sharedHash)
        let collection = try store.createCollection(named: "Redaction Sweep")
        try store.setMembership(contentHash: sharedHash, inCollection: collection.id, isMember: true)

        let redactor = ClipboardArchiveRedactor(archiveRoot: root, indexURL: indexURL)
        let firstResult = try redactor.redact(eventID: fixtures.newer.id)
        #expect(firstResult.removedAnnotationContentHash == nil)
        #expect(store.annotation(for: sharedHash) != nil)

        let secondResult = try redactor.redact(eventID: fixtures.older.id)
        #expect(secondResult.removedAnnotationContentHash == sharedHash)
        #expect(store.annotation(for: sharedHash) == nil)
        #expect(store.collections().first?.contentHashes == [])
    }

    // MARK: - Stale index must not keep an annotation alive

    @Test
    func testStaleIndexRowIsTreatedAsDeadViaLedgerFilter() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let indexURL = root.appendingPathComponent("index.sqlite")
        let fixtures = try seedTwoOccurrences(archiveRoot: root)
        _ = try ClipboardDerivedIndex(archiveRoot: root, indexURL: indexURL).rebuild()

        let store = ClipboardAnnotationsStore(archiveRoot: root)
        try store.setPinned(true, forContentHash: sharedHash)

        // Manufacture drift: the newer occurrence gets a deletion-ledger
        // record WITHOUT the matching index delete, so its index row is
        // stale. Redacting the older (last actually-live) occurrence must
        // still remove the annotation — the resolver filters ledger ids.
        try ClipboardDeletionLedger(archiveRoot: root)
            .recordDeletion(eventID: fixtures.newer.id, reason: "test-drift")

        let result = try ClipboardArchiveRedactor(archiveRoot: root, indexURL: indexURL)
            .redact(eventID: fixtures.older.id)

        #expect(result.removedAnnotationContentHash == sharedHash)
        #expect(store.annotation(for: sharedHash) == nil)
    }

    // MARK: - Index-file-absent fallback (one reader scan)

    @Test
    func testIndexAbsentFallsBackToReaderScan() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let indexURL = root.appendingPathComponent("missing-index.sqlite")
        let fixtures = try seedTwoOccurrences(archiveRoot: root)
        // Deliberately NO index rebuild: the resolver must scan the reader.

        let store = ClipboardAnnotationsStore(archiveRoot: root)
        try store.setTags(["survives-scan"], forContentHash: sharedHash)

        let resolved = try ClipboardOccurrenceResolver(archiveRoot: root, indexURL: indexURL)
            .liveOccurrenceIDs(contentHash: sharedHash)
        #expect(resolved == [fixtures.newer.id, fixtures.older.id])

        let redactor = ClipboardArchiveRedactor(archiveRoot: root, indexURL: indexURL)
        let firstResult = try redactor.redact(eventID: fixtures.newer.id)
        #expect(firstResult.removedAnnotationContentHash == nil)
        #expect(store.annotation(for: sharedHash)?.tags == ["survives-scan"])

        let secondResult = try redactor.redact(eventID: fixtures.older.id)
        #expect(secondResult.removedAnnotationContentHash == sharedHash)
        #expect(store.annotation(for: sharedHash) == nil)
    }

    // MARK: - Unannotated content never touches the store

    @Test
    func testRedactingUnannotatedContentLeavesStoreAbsent() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let indexURL = root.appendingPathComponent("index.sqlite")
        let fixtures = try seedTwoOccurrences(archiveRoot: root)
        _ = try ClipboardDerivedIndex(archiveRoot: root, indexURL: indexURL).rebuild()

        let result = try ClipboardArchiveRedactor(archiveRoot: root, indexURL: indexURL)
            .redact(eventID: fixtures.newer.id)

        #expect(result.removedAnnotationContentHash == nil)
        let store = ClipboardAnnotationsStore(archiveRoot: root)
        #expect(!FileManager.default.fileExists(atPath: store.annotationsFileURL.path))
    }
}
