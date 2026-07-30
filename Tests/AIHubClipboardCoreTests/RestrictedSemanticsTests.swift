import Foundation
import Testing
@testable import ClipboardArchiveCore

/// Slice 5 `.restricted` semantics (binding decision): stored, visible,
/// NEVER searchable. One gate file, two tested predicates — `isSuppressed`
/// unchanged, `isIndexExcluded` added. Synthetic fixtures under temp roots
/// only (contract 10).
@Suite("Restricted Semantics")
struct RestrictedSemanticsTests {
    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("clipboard-restricted-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private struct Fixture {
        var archiveRoot: URL
        var indexURL: URL
        var writer: ClipboardArchiveWriter
        var index: ClipboardDerivedIndex
        var reader: ClipboardArchiveReader
        var annotations: ClipboardAnnotationsStore
    }

    private func makeFixture() throws -> Fixture {
        let archiveRoot = try temporaryDirectory()
        let indexURL = try temporaryDirectory().appendingPathComponent("index.sqlite")
        return Fixture(
            archiveRoot: archiveRoot,
            indexURL: indexURL,
            writer: ClipboardArchiveWriter(archiveRoot: archiveRoot),
            index: ClipboardDerivedIndex(archiveRoot: archiveRoot, indexURL: indexURL),
            reader: ClipboardArchiveReader(archiveRoot: archiveRoot),
            annotations: ClipboardAnnotationsStore(archiveRoot: archiveRoot)
        )
    }

    @Test func testPredicateShapes() throws {
        var event = SyntheticFixtures.currentEvent()
        #expect(!ClipboardSuppression.isIndexExcluded(event))
        #expect(ClipboardSuppression.isIndexExcluded(event, sensitivityOverride: "restricted"))
        #expect(!ClipboardSuppression.isIndexExcluded(event, sensitivityOverride: "something-else"))
        event.privacyLabel = .restricted
        #expect(ClipboardSuppression.isIndexExcluded(event))
        event.privacyLabel = .doNotIndex
        #expect(ClipboardSuppression.isIndexExcluded(event))
    }

    @Test func testRestrictedLabelVisibleToReaderButNotSuppressed() throws {
        let fixture = try makeFixture()
        let event = try fixture.writer.archiveAllowedCapture(
            ClipboardCapture(
                content: "restricted label visibility fixture",
                sourceApp: ClipboardSourceApp(name: "CRM", bundleIdentifier: "com.example.crm")
            ),
            privacyLabel: .restricted,
            sensitivityFlags: ["app-rule-no-index"]
        )
        // Visible: isSuppressed is UNCHANGED by restriction.
        let suppression = try ClipboardSuppression(archiveRoot: fixture.archiveRoot).snapshot()
        let stored = try #require(try fixture.reader.recentItems(since: .distantPast, limit: 5).first)
        #expect(stored.id == event.id)
        #expect(!suppression.isSuppressed(stored))
        #expect(ClipboardSuppression.isIndexExcluded(stored))
    }

    @Test func testRestrictedLabelAbsentFromRebuildUpsertSearchBrowse() throws {
        let fixture = try makeFixture()
        let plain = try fixture.writer.archiveAllowedCapture(ClipboardCapture(
            content: "plain searchable fixture token",
            sourceApp: ClipboardSourceApp(name: "Notes", bundleIdentifier: "com.apple.Notes")
        ))
        let restricted = try fixture.writer.archiveAllowedCapture(
            ClipboardCapture(
                content: "restricted unsearchable fixture token",
                sourceApp: ClipboardSourceApp(name: "CRM", bundleIdentifier: "com.example.crm")
            ),
            privacyLabel: .restricted
        )

        // Rebuild skips restricted.
        let count = try fixture.index.rebuild()
        #expect(count == 1)
        #expect(try fixture.index.occurrenceIDs(contentHash: restricted.contentHash).isEmpty)

        // Upsert deletes-instead-of-inserts.
        try fixture.index.upsert(event: restricted, body: "restricted unsearchable fixture token")
        #expect(try fixture.index.occurrenceIDs(contentHash: restricted.contentHash).isEmpty)

        // Structured search and browse never return it.
        let hits = try fixture.index.structuredSearch("fixture")
        #expect(hits.map(\.id) == [plain.id])
        let rows = try fixture.index.browse()
        #expect(rows.map(\.id) == [plain.id])

        // CLI archive searcher skips it too.
        let cli = try ClipboardArchiveSearcher(archiveRoot: fixture.archiveRoot)
            .search(ClipboardSearchOptions(query: "unsearchable fixture token"))
        #expect(cli.isEmpty)
    }

    @Test func testManualOverrideExcludesExistingAndRecopiedContent() throws {
        let fixture = try makeFixture()
        let content = "manual override recopy fixture token"
        let original = try fixture.writer.archiveAllowedCapture(ClipboardCapture(
            content: content,
            sourceApp: ClipboardSourceApp(name: "Notes", bundleIdentifier: "com.apple.Notes")
        ))
        _ = try fixture.index.rebuild()
        #expect(try fixture.index.occurrenceIDs(contentHash: original.contentHash) == [original.id])

        // Mark restricted via the annotation override (event lines are
        // never rewritten), then rebuild: the row disappears.
        try fixture.annotations.setSensitivityOverride("restricted", forContentHash: original.contentHash)
        _ = try fixture.index.rebuild()
        #expect(try fixture.index.occurrenceIDs(contentHash: original.contentHash).isEmpty)

        // A RE-COPY of the same content ingested through the production
        // path skips indexing and carries the manual-restricted flag.
        let ingestor = ClipboardIngestor(
            archiveWriter: fixture.writer,
            derivedIndex: fixture.index
        )
        let result = try ingestor.ingest(ClipboardCapture(
            content: content,
            sourceApp: ClipboardSourceApp(name: "Notes", bundleIdentifier: "com.apple.Notes")
        ))
        guard case let .stored(recopy, indexUpdate) = result else {
            Issue.record("re-copy should store")
            return
        }
        #expect(indexUpdate == .excluded)
        #expect(recopy.sensitivityFlags.contains("manual-restricted"))
        #expect(recopy.privacyLabel == .privateLocal)
        #expect(try fixture.index.occurrenceIDs(contentHash: original.contentHash).isEmpty)
        // Both occurrences stay reader-visible.
        #expect(try fixture.reader.recentItems(since: .distantPast, limit: 10).count == 2)
        // The event line on disk was never rewritten to carry the override.
        let cliHits = try ClipboardArchiveSearcher(archiveRoot: fixture.archiveRoot)
            .search(ClipboardSearchOptions(query: "recopy fixture token"))
        #expect(cliHits.isEmpty)
    }

    @Test func testClearingOverrideReindexesOccurrences() throws {
        let fixture = try makeFixture()
        let content = "clear override reindex fixture token"
        let event = try fixture.writer.archiveAllowedCapture(ClipboardCapture(
            content: content,
            sourceApp: ClipboardSourceApp(name: "Notes", bundleIdentifier: "com.apple.Notes")
        ))
        try fixture.annotations.setSensitivityOverride("restricted", forContentHash: event.contentHash)
        _ = try fixture.index.rebuild()
        #expect(try fixture.index.occurrenceIDs(contentHash: event.contentHash).isEmpty)

        // Clear, then re-upsert the occurrence (the UI's clear path).
        try fixture.annotations.setSensitivityOverride(nil, forContentHash: event.contentHash)
        try fixture.index.upsert(event: event, body: content)
        #expect(try fixture.index.occurrenceIDs(contentHash: event.contentHash) == [event.id])
        let hits = try fixture.index.structuredSearch("reindex")
        #expect(hits.map(\.id) == [event.id])
    }

    @Test func testTombstonesRemainDoNotIndexNotRestricted() throws {
        let fixture = try makeFixture()
        let event = try fixture.writer.archiveAllowedCapture(ClipboardCapture(
            content: "tombstone label fixture",
            sourceApp: ClipboardSourceApp(name: "Notes", bundleIdentifier: "com.apple.Notes")
        ))
        try ClipboardArchiveRedactor(archiveRoot: fixture.archiveRoot, indexURL: fixture.indexURL)
            .redact(eventID: event.id)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        var tombstone: StoredClipboardEvent?
        for fileURL in try fixture.reader.eventFiles() {
            for line in try String(contentsOf: fileURL).split(separator: "\n", omittingEmptySubsequences: true) {
                if let decoded = try? decoder.decode(StoredClipboardEvent.self, from: Data(String(line).utf8)),
                   decoded.id == event.id {
                    tombstone = decoded
                }
            }
        }
        #expect(try #require(tombstone).privacyLabel == .doNotIndex)
    }

    @Test func testAnnotationStoreRoundTripsOverrideAndListsRestrictedHashes() throws {
        let fixture = try makeFixture()
        try fixture.annotations.setSensitivityOverride("restricted", forContentHash: "sha256:aaa")
        try fixture.annotations.setSensitivityOverride("restricted", forContentHash: "sha256:bbb")
        try fixture.annotations.setSensitivityOverride(nil, forContentHash: "sha256:bbb")
        #expect(fixture.annotations.restrictedContentHashes() == ["sha256:aaa"])
        // Clearing the only field GCs the record entirely.
        #expect(fixture.annotations.annotation(for: "sha256:bbb") == nil)
    }
}
