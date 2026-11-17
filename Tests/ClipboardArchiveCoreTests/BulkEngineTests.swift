import Foundation
import Testing
@testable import ClipboardArchiveCore

/// Slice 5 bulk engine (contracts 5/6): preview/execute parity by
/// construction, truthful reclaim accounting, every criterion, pinned
/// exemption + includePinned override, machine-readable ledger reasons,
/// drift honesty, tombstone field parity with the redactor, and the
/// day-range scan bound. Synthetic fixtures under temp roots only.
@Suite("Bulk Engine")
struct BulkEngineTests {
    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("clipboard-bulk-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private struct Fixture {
        var archiveRoot: URL
        var indexURL: URL
        var writer: ClipboardArchiveWriter
        var engine: ClipboardBulkEngine
        var annotations: ClipboardAnnotationsStore
        var reader: ClipboardArchiveReader
    }

    private func makeFixture(inlineLimit: Int = 64 * 1024) throws -> Fixture {
        let archiveRoot = try temporaryDirectory()
        let indexURL = try temporaryDirectory().appendingPathComponent("index.sqlite")
        return Fixture(
            archiveRoot: archiveRoot,
            indexURL: indexURL,
            writer: ClipboardArchiveWriter(archiveRoot: archiveRoot, inlineContentLimitBytes: inlineLimit),
            engine: ClipboardBulkEngine(archiveRoot: archiveRoot, indexURL: indexURL),
            annotations: ClipboardAnnotationsStore(archiveRoot: archiveRoot),
            reader: ClipboardArchiveReader(archiveRoot: archiveRoot)
        )
    }

    @discardableResult
    private func seed(
        _ fixture: Fixture,
        content: String,
        minutesAgo: Double,
        app: ClipboardSourceApp = ClipboardSourceApp(name: "Notes", bundleIdentifier: "com.apple.Notes")
    ) throws -> StoredClipboardEvent {
        try fixture.writer.archiveAllowedCapture(ClipboardCapture(
            capturedAt: Date().addingTimeInterval(-minutesAgo * 60),
            content: content,
            sourceApp: app,
            pasteboardTypes: ["public.utf8-plain-text"]
        ))
    }

    private func directoryBytes(_ root: URL) -> Int64 {
        let urls = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey]
        )?.compactMap { $0 as? URL } ?? []
        return urls.reduce(Int64(0)) { total, url in
            guard (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true,
                  let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize else {
                return total
            }
            return total + Int64(size)
        }
    }

    @Test func testPreviewAndExecuteReportIdenticalNumbers() throws {
        let fixture = try makeFixture(inlineLimit: 32)
        try seed(fixture, content: "short bulk fixture one", minutesAgo: 10)
        try seed(fixture, content: String(repeating: "large bulk fixture body line\n", count: 30), minutesAgo: 20)
        try seed(fixture, content: "short bulk fixture keep", minutesAgo: 1)

        let criteria = ClipboardBulkCriteria(until: Date().addingTimeInterval(-5 * 60))
        let preview = try fixture.engine.preview(criteria)
        let executed = try fixture.engine.execute(criteria)

        #expect(preview.dryRun)
        #expect(!executed.dryRun)
        #expect(preview.matchedEvents == 2)
        #expect(preview.matchedEvents == executed.matchedEvents)
        #expect(preview.reclaimedBytes == executed.reclaimedBytes)
        #expect(preview.deletedBodyFiles == executed.deletedBodyFiles)
        #expect(preview.changedFiles == executed.changedFiles)
        #expect(preview.exemptedPinnedEvents == executed.exemptedPinnedEvents)
        #expect(preview.reason == executed.reason)
    }

    @Test func testReclaimedBytesMatchesOnDiskByteDelta() throws {
        let fixture = try makeFixture(inlineLimit: 32)
        try seed(fixture, content: "inline bulk delta fixture with some padding text here", minutesAgo: 30)
        try seed(fixture, content: String(repeating: "body-file bulk delta fixture line\n", count: 40), minutesAgo: 40)
        try seed(fixture, content: "surviving clip stays put", minutesAgo: 1)

        // Byte-delta truth is measured against the raw event/body tree
        // only: executing also APPENDS deletion-ledger lines under the same
        // archive root, which is bookkeeping, not reclaimable content.
        let rawRoot = fixture.archiveRoot.appendingPathComponent("raw")
        let criteria = ClipboardBulkCriteria(until: Date().addingTimeInterval(-10 * 60))
        let preview = try fixture.engine.preview(criteria)
        let bytesBefore = directoryBytes(rawRoot)
        let executed = try fixture.engine.execute(criteria)
        let bytesAfter = directoryBytes(rawRoot)

        #expect(executed.matchedEvents == 2)
        #expect(preview.reclaimedBytes == executed.reclaimedBytes)
        #expect(bytesBefore - bytesAfter == executed.reclaimedBytes)
        #expect(executed.reclaimedBytes > 0)
    }

    @Test func testEveryCriterionSelectsExactly() throws {
        let fixture = try makeFixture()
        let notes = ClipboardSourceApp(name: "Notes", bundleIdentifier: "com.apple.Notes")
        let xcode = ClipboardSourceApp(name: "Xcode", bundleIdentifier: "com.apple.dt.Xcode")
        let old = try seed(fixture, content: "old bulk criterion fixture", minutesAgo: 600, app: notes)
        let url = try seed(fixture, content: "https://example.com/bulk-criterion", minutesAgo: 50, app: xcode)
        let code = try seed(
            fixture,
            content: "func bulk() {\n    let criterion = 1\n}\nstruct T {}",
            minutesAgo: 40,
            app: xcode
        )
        let fresh = try seed(fixture, content: "fresh bulk criterion fixture", minutesAgo: 1, app: notes)

        // until
        #expect(try fixture.engine.preview(
            ClipboardBulkCriteria(until: Date().addingTimeInterval(-300 * 60))
        ).matchedEvents == 1)
        // since
        #expect(try fixture.engine.preview(
            ClipboardBulkCriteria(since: Date().addingTimeInterval(-60 * 60))
        ).matchedEvents == 3)
        // bundleID (case-insensitive)
        #expect(try fixture.engine.preview(
            ClipboardBulkCriteria(bundleID: "COM.APPLE.DT.XCODE")
        ).matchedEvents == 2)
        // sourceAppName
        #expect(try fixture.engine.preview(
            ClipboardBulkCriteria(sourceAppName: "Notes")
        ).matchedEvents == 2)
        // contentType
        #expect(try fixture.engine.preview(
            ClipboardBulkCriteria(contentType: "url")
        ).matchedEvents == 1)
        // eventIDs
        #expect(try fixture.engine.preview(
            ClipboardBulkCriteria(eventIDs: [old.id, fresh.id])
        ).matchedEvents == 2)
        // AND-composition
        #expect(try fixture.engine.preview(
            ClipboardBulkCriteria(
                since: Date().addingTimeInterval(-60 * 60),
                bundleID: "com.apple.dt.xcode",
                contentType: "code"
            )
        ).matchedEvents == 1)
        _ = (url, code)
    }

    @Test func testSensitivityCriteria() throws {
        let fixture = try makeFixture()
        let plain = try seed(fixture, content: "plain unflagged clip", minutesAgo: 5)
        let manual = try seed(fixture, content: "manually restricted clip", minutesAgo: 6)
        try fixture.annotations.setSensitivityOverride("restricted", forContentHash: manual.contentHash)
        // A store-no-index event carries the .restricted label on its line.
        let ingestor = ClipboardIngestor(
            filter: ClipboardPrivacyFilter(
                appPrivacyRules: ["com.example.crm": ClipboardAppPrivacyRule(mode: "store-no-index")]
            ),
            archiveWriter: fixture.writer
        )
        guard case .stored = try ingestor.ingest(ClipboardCapture(
            content: "labelled restricted clip",
            sourceApp: ClipboardSourceApp(name: "CRM", bundleIdentifier: "com.example.crm")
        )) else {
            Issue.record("store-no-index capture was not stored")
            return
        }

        #expect(try fixture.engine.preview(
            ClipboardBulkCriteria(sensitivity: .manualRestricted)
        ).matchedEvents == 1)
        #expect(try fixture.engine.preview(
            ClipboardBulkCriteria(sensitivity: .anyFlagged)
        ).matchedEvents == 2)
        _ = plain
    }

    @Test func testPinnedExemptionAndIncludePinnedOverride() throws {
        let fixture = try makeFixture()
        let pinned = try seed(fixture, content: "pinned bulk fixture", minutesAgo: 100)
        try seed(fixture, content: "unpinned bulk fixture", minutesAgo: 90)
        try fixture.annotations.setPinned(true, forContentHash: pinned.contentHash)

        let exempting = try fixture.engine.preview(
            ClipboardBulkCriteria(until: Date().addingTimeInterval(-60 * 60))
        )
        #expect(exempting.matchedEvents == 1)
        #expect(exempting.exemptedPinnedEvents == 1)

        let including = try fixture.engine.execute(
            ClipboardBulkCriteria(until: Date().addingTimeInterval(-60 * 60), includePinned: true)
        )
        #expect(including.matchedEvents == 2)
        #expect(including.exemptedPinnedEvents == 0)
        let remaining = try fixture.reader.recentItems(since: .distantPast, limit: 10)
        #expect(remaining.isEmpty)
        // Last-occurrence sweep removed the pin's annotation record.
        #expect(fixture.annotations.annotation(for: pinned.contentHash) == nil)
        #expect(including.removedAnnotationHashes == 1)
    }

    @Test func testLedgerReasonNamesSortedActiveCriteria() throws {
        let fixture = try makeFixture()
        let target = try seed(fixture, content: "ledger reason fixture", minutesAgo: 30)

        let criteria = ClipboardBulkCriteria(
            until: Date().addingTimeInterval(-10 * 60),
            bundleID: "com.apple.notes"
        )
        #expect(criteria.ledgerReason == "bulk-bundleID+until")
        try fixture.engine.execute(criteria)

        let ledgerRoot = fixture.archiveRoot.appendingPathComponent("deletion-ledger")
        let ledgerFiles = FileManager.default.enumerator(at: ledgerRoot, includingPropertiesForKeys: nil)?
            .compactMap { $0 as? URL }
            .filter { $0.pathExtension == "ndjson" } ?? []
        let ledgerText = try ledgerFiles.map { try String(contentsOf: $0) }.joined()
        #expect(ledgerText.contains(target.id))
        #expect(ledgerText.contains("\"reason\":\"bulk-bundleID+until\""))
    }

    @Test func testAlreadyDeletedDriftIsNeverDoubleCounted() throws {
        let fixture = try makeFixture()
        let drifted = try seed(fixture, content: "drifted bulk fixture", minutesAgo: 30)
        try seed(fixture, content: "live bulk fixture", minutesAgo: 25)
        try ClipboardDeletionLedger(archiveRoot: fixture.archiveRoot)
            .recordDeletion(eventID: drifted.id, reason: "synthetic-drift")

        let preview = try fixture.engine.preview(
            ClipboardBulkCriteria(until: Date().addingTimeInterval(-10 * 60))
        )
        #expect(preview.matchedEvents == 1)
        let executed = try fixture.engine.execute(
            ClipboardBulkCriteria(until: Date().addingTimeInterval(-10 * 60))
        )
        #expect(executed.matchedEvents == 1)
    }

    @Test func testBulkTombstoneFieldsMatchRedactorSemantics() throws {
        let fixture = try makeFixture(inlineLimit: 16)
        let bulkTarget = try seed(
            fixture,
            content: String(repeating: "bulk tombstone parity fixture\n", count: 5),
            minutesAgo: 30
        )
        let redactTarget = try seed(
            fixture,
            content: String(repeating: "redactor tombstone parity fixture\n", count: 5),
            minutesAgo: 29
        )

        try fixture.engine.execute(ClipboardBulkCriteria(eventIDs: [bulkTarget.id]))
        try ClipboardArchiveRedactor(archiveRoot: fixture.archiveRoot, indexURL: fixture.indexURL)
            .redact(eventID: redactTarget.id)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        var bulkTombstone: StoredClipboardEvent?
        var redactorTombstone: StoredClipboardEvent?
        for fileURL in try fixture.reader.eventFiles() {
            for line in try String(contentsOf: fileURL).split(separator: "\n", omittingEmptySubsequences: true) {
                guard let event = try? decoder.decode(
                    StoredClipboardEvent.self,
                    from: Data(String(line).utf8)
                ) else {
                    continue
                }
                if event.id == bulkTarget.id { bulkTombstone = event }
                if event.id == redactTarget.id { redactorTombstone = event }
            }
        }
        let bulk = try #require(bulkTombstone)
        let redacted = try #require(redactorTombstone)
        // Field treatment parity: same cleared content fields, same label
        // and allowedUse; only the preview text and flag family differ.
        #expect(bulk.contentInline == nil && redacted.contentInline == nil)
        #expect(bulk.rawContentPath == nil && redacted.rawContentPath == nil)
        #expect(bulk.privacyLabel == .doNotIndex && redacted.privacyLabel == .doNotIndex)
        #expect(bulk.allowedUse == [.doNotIndex] && redacted.allowedUse == [.doNotIndex])
        #expect(bulk.contentPreview == "[pruned]")
        #expect(redacted.contentPreview == "[deleted]")
        // Body files are gone for both.
        #expect(try fixture.reader.recentItems(since: .distantPast, limit: 10).isEmpty)
    }

    @Test func testDayRangeBoundsTheFileScan() throws {
        let fixture = try makeFixture()
        // One event ~100 days old, one fresh.
        let oldDate = Date().addingTimeInterval(-100 * 86_400)
        try fixture.writer.archiveAllowedCapture(ClipboardCapture(
            capturedAt: oldDate,
            content: "day-range old fixture",
            sourceApp: ClipboardSourceApp(name: "Notes", bundleIdentifier: "com.apple.Notes"),
            pasteboardTypes: ["public.utf8-plain-text"]
        ))
        try seed(fixture, content: "day-range fresh fixture", minutesAgo: 1)

        // Range covering only the recent day: the old day file must not
        // even be scanned (scannedEvents proves the bound), and it stays
        // byte-identical on execute.
        let oldFile = try #require(try fixture.reader.eventFiles().min(by: { $0.path < $1.path }))
        let oldBytes = try Data(contentsOf: oldFile)

        let recentCriteria = ClipboardBulkCriteria(since: Date().addingTimeInterval(-2 * 86_400))
        let outcome = try ClipboardArchivePruner(
            archiveRoot: fixture.archiveRoot,
            indexURL: fixture.indexURL
        ).pruneCore(
            dryRun: false,
            reason: recentCriteria.ledgerReason,
            exemptContentHashes: [],
            restrictToDayRange: (recentCriteria.since ?? .distantPast)...Date.distantFuture
        ) { _ in true }

        #expect(outcome.result.scannedEvents == 1)
        #expect(outcome.result.prunedEvents == 1)
        #expect(try Data(contentsOf: oldFile) == oldBytes)
    }

    @Test func testExecuteRemovesIndexRowsBeforeTombstoning() throws {
        let fixture = try makeFixture()
        let target = try seed(fixture, content: "bulk index cleanup fixture token", minutesAgo: 30)
        let index = ClipboardDerivedIndex(archiveRoot: fixture.archiveRoot, indexURL: fixture.indexURL)
        _ = try index.rebuild()
        #expect(try index.occurrenceIDs(contentHash: target.contentHash).contains(target.id))

        try fixture.engine.execute(ClipboardBulkCriteria(eventIDs: [target.id]))
        #expect(try index.occurrenceIDs(contentHash: target.contentHash).isEmpty)
    }
}
