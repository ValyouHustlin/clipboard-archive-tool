import Foundation
import Testing
@testable import ClipboardArchiveCore

/// Slice 5 expiring sensitive clips: due/not-due behavior, zero-archive-IO
/// nextDue, pinned content swept (expiry is an explicit instruction),
/// `expired-sensitive` ledger reason, and the index-absent reader-scan
/// fallback. Synthetic fixtures under temp roots only (contract 10).
@Suite("Expiry Sweeper")
struct ExpirySweeperTests {
    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("clipboard-expiry-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private struct Fixture {
        var archiveRoot: URL
        var indexURL: URL
        var writer: ClipboardArchiveWriter
        var annotations: ClipboardAnnotationsStore
        var sweeper: ClipboardExpirySweeper
        var reader: ClipboardArchiveReader
    }

    private func makeFixture() throws -> Fixture {
        let archiveRoot = try temporaryDirectory()
        let indexURL = try temporaryDirectory().appendingPathComponent("index.sqlite")
        return Fixture(
            archiveRoot: archiveRoot,
            indexURL: indexURL,
            writer: ClipboardArchiveWriter(archiveRoot: archiveRoot),
            annotations: ClipboardAnnotationsStore(archiveRoot: archiveRoot),
            sweeper: ClipboardExpirySweeper(archiveRoot: archiveRoot, indexURL: indexURL),
            reader: ClipboardArchiveReader(archiveRoot: archiveRoot)
        )
    }

    @Test func testNotDueDoesNothing() throws {
        let fixture = try makeFixture()
        let event = try fixture.writer.archiveAllowedCapture(ClipboardCapture(
            content: "not due expiry fixture",
            sourceApp: ClipboardSourceApp(name: "Notes", bundleIdentifier: "com.apple.Notes")
        ))
        try fixture.annotations.setExpiry(Date().addingTimeInterval(3_600), forContentHash: event.contentHash)

        #expect(fixture.sweeper.nextDue() != nil)
        let result = try fixture.sweeper.sweepIfDue()
        #expect(result.sweptContentHashes == 0)
        #expect(result.deletedEvents == 0)
        #expect(try fixture.reader.recentItems(since: .distantPast, limit: 5).count == 1)
        #expect(fixture.annotations.annotation(for: event.contentHash)?.expiresAt != nil)
    }

    @Test func testDueSweepDeletesAllOccurrencesAndClearsAnnotation() throws {
        let fixture = try makeFixture()
        let content = "due expiry sweep fixture token"
        let first = try fixture.writer.archiveAllowedCapture(ClipboardCapture(
            capturedAt: Date().addingTimeInterval(-600),
            content: content,
            sourceApp: ClipboardSourceApp(name: "Notes", bundleIdentifier: "com.apple.Notes")
        ))
        try fixture.writer.archiveAllowedCapture(ClipboardCapture(
            capturedAt: Date().addingTimeInterval(-300),
            content: content,
            sourceApp: ClipboardSourceApp(name: "Safari", bundleIdentifier: "com.apple.Safari")
        ))
        try fixture.writer.archiveAllowedCapture(ClipboardCapture(
            content: "unrelated survivor clip",
            sourceApp: ClipboardSourceApp(name: "Notes", bundleIdentifier: "com.apple.Notes")
        ))
        _ = try ClipboardDerivedIndex(archiveRoot: fixture.archiveRoot, indexURL: fixture.indexURL).rebuild()
        try fixture.annotations.setExpiry(Date().addingTimeInterval(-60), forContentHash: first.contentHash)

        let result = try fixture.sweeper.sweepIfDue()
        #expect(result.sweptContentHashes == 1)
        #expect(result.deletedEvents == 2)
        let remaining = try fixture.reader.recentItems(since: .distantPast, limit: 10)
        #expect(remaining.count == 1)
        #expect(remaining.first?.contentPreview == "unrelated survivor clip")
        // Annotation record fully cleared — the expiry never re-fires.
        #expect(fixture.annotations.annotation(for: first.contentHash) == nil)
        #expect(fixture.sweeper.nextDue() == nil)
        let second = try fixture.sweeper.sweepIfDue()
        #expect(second.sweptContentHashes == 0)
    }

    @Test func testSweepDeletesPinnedContentWithExpiredSensitiveReason() throws {
        let fixture = try makeFixture()
        let event = try fixture.writer.archiveAllowedCapture(ClipboardCapture(
            content: "pinned expiring fixture",
            sourceApp: ClipboardSourceApp(name: "Notes", bundleIdentifier: "com.apple.Notes")
        ))
        try fixture.annotations.setPinned(true, forContentHash: event.contentHash)
        try fixture.annotations.setExpiry(Date().addingTimeInterval(-1), forContentHash: event.contentHash)

        let result = try fixture.sweeper.sweepIfDue()
        #expect(result.deletedEvents == 1)
        #expect(try fixture.reader.recentItems(since: .distantPast, limit: 5).isEmpty)

        let ledgerRoot = fixture.archiveRoot.appendingPathComponent("deletion-ledger")
        let ledgerFiles = FileManager.default.enumerator(at: ledgerRoot, includingPropertiesForKeys: nil)?
            .compactMap { $0 as? URL }
            .filter { $0.pathExtension == "ndjson" } ?? []
        let ledgerText = try ledgerFiles.map { try String(contentsOf: $0) }.joined()
        #expect(ledgerText.contains("\"reason\":\"expired-sensitive\""))
        #expect(ledgerText.contains(event.id))
    }

    @Test func testNextDueUsesAnnotationsOnlyZeroArchiveIO() throws {
        // No raw/ directory exists at all: nextDue must still answer from
        // the annotations sidecar alone.
        let fixture = try makeFixture()
        let due = Date(timeIntervalSince1970: 1_900_000_000)
        try fixture.annotations.setExpiry(due, forContentHash: "sha256:zero-io-fixture")
        #expect(!FileManager.default.fileExists(
            atPath: fixture.archiveRoot.appendingPathComponent("raw").path
        ))
        #expect(fixture.sweeper.nextDue() == due)
    }

    @Test func testIndexAbsentFallsBackToReaderScan() throws {
        let fixture = try makeFixture()
        let event = try fixture.writer.archiveAllowedCapture(ClipboardCapture(
            content: "index absent fallback fixture",
            sourceApp: ClipboardSourceApp(name: "Notes", bundleIdentifier: "com.apple.Notes")
        ))
        try fixture.annotations.setExpiry(Date().addingTimeInterval(-1), forContentHash: event.contentHash)
        #expect(!FileManager.default.fileExists(atPath: fixture.indexURL.path))

        let result = try fixture.sweeper.sweepIfDue()
        #expect(result.deletedEvents == 1)
        #expect(try fixture.reader.recentItems(since: .distantPast, limit: 5).isEmpty)
    }

    @Test func testMultipleDueHashesSweepIndependently() throws {
        let fixture = try makeFixture()
        let first = try fixture.writer.archiveAllowedCapture(ClipboardCapture(
            content: "first due fixture",
            sourceApp: ClipboardSourceApp(name: "Notes", bundleIdentifier: "com.apple.Notes")
        ))
        let second = try fixture.writer.archiveAllowedCapture(ClipboardCapture(
            content: "second due fixture",
            sourceApp: ClipboardSourceApp(name: "Notes", bundleIdentifier: "com.apple.Notes")
        ))
        let keeper = try fixture.writer.archiveAllowedCapture(ClipboardCapture(
            content: "future expiry fixture",
            sourceApp: ClipboardSourceApp(name: "Notes", bundleIdentifier: "com.apple.Notes")
        ))
        try fixture.annotations.setExpiry(Date().addingTimeInterval(-120), forContentHash: first.contentHash)
        try fixture.annotations.setExpiry(Date().addingTimeInterval(-60), forContentHash: second.contentHash)
        try fixture.annotations.setExpiry(Date().addingTimeInterval(3_600), forContentHash: keeper.contentHash)

        let result = try fixture.sweeper.sweepIfDue()
        #expect(result.sweptContentHashes == 2)
        #expect(result.deletedEvents == 2)
        let remaining = try fixture.reader.recentItems(since: .distantPast, limit: 5)
        #expect(remaining.map(\.id) == [keeper.id])
        #expect(fixture.sweeper.nextDue() != nil)
    }
}
