import Foundation
import Testing
@testable import ClipboardArchiveCore

/// The derived index is disposable data with one recovery path: rebuild it
/// from the archive. These tests pin that a file deleted or damaged while
/// the process is running is DETECTED rather than trusted — the failure this
/// covers is silent, because the sqlite3 CLI creates an empty database on
/// open and history simply shrinks. Synthetic data, temporary roots only.
@Suite("Derived index self-heal")
struct IndexSelfHealTests {
    private struct Fixture {
        var base: URL
        var archiveRoot: URL
        var indexURL: URL
        var log: ClipboardOperationalLog
        var index: ClipboardDerivedIndex
        var ingestor: ClipboardIngestor
    }

    private func makeFixture() throws -> Fixture {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("clipboard-index-selfheal-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let archiveRoot = base.appendingPathComponent("archive", isDirectory: true)
        let indexURL = base.appendingPathComponent("index.sqlite")
        let log = ClipboardOperationalLog(directory: base.appendingPathComponent("Logs", isDirectory: true))
        let index = ClipboardDerivedIndex(archiveRoot: archiveRoot, indexURL: indexURL, operationalLog: log)
        return Fixture(
            base: base,
            archiveRoot: archiveRoot,
            indexURL: indexURL,
            log: log,
            index: index,
            ingestor: ClipboardIngestor(
                archiveWriter: ClipboardArchiveWriter(archiveRoot: archiveRoot),
                derivedIndex: index,
                operationalLog: log
            )
        )
    }

    private func capture(_ content: String, offset: TimeInterval) -> ClipboardCapture {
        ClipboardCapture(
            capturedAt: Date(timeIntervalSince1970: 1_800_000_000 + offset),
            content: content,
            sourceApp: ClipboardSourceApp(name: "Self Heal Test", bundleIdentifier: "test.selfheal"),
            pasteboardTypes: ["public.utf8-plain-text"]
        )
    }

    private func codes(_ log: ClipboardOperationalLog) -> [String] {
        log.read(limit: 200).map(\.code)
    }

    /// An index deleted mid-run: the next capture must not quietly rebuild
    /// an EMPTY database holding only the new row. Everything captured
    /// before the deletion has to come back.
    @Test func captureAfterIndexDeletionRebuildsTheWholeArchive() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.base) }

        _ = try fixture.ingestor.ingest(capture("alphamarker before the deletion", offset: 0))
        try FileManager.default.removeItem(at: fixture.indexURL)

        let result = try fixture.ingestor.ingest(capture("betamarker after the deletion", offset: 1))
        guard case let .stored(_, status) = result else {
            Issue.record("capture was not stored")
            return
        }
        // The capture path never blocks on a rebuild: it defers and the
        // background queue does the work.
        #expect(status == .deferred)
        #expect(ClipboardDerivedIndex.waitForPendingRebuilds(forIndexAt: fixture.indexURL, timeout: 60))

        let alpha = try fixture.index.structuredSearch("alphamarker")
        let beta = try fixture.index.structuredSearch("betamarker")
        let logged = codes(fixture.log)
        print("SELFHEAL_DELETED alpha=\(alpha.count) beta=\(beta.count) user_version=\(fixture.index.userVersion() ?? -1) codes=\(logged)")
        #expect(alpha.count == 1)
        #expect(beta.count == 1)
        #expect(logged.contains("index_missing_detected"))
        #expect(logged.contains("index_rebuild_finished"))
        #expect(fixture.index.userVersion() == ClipboardDerivedIndex.currentIndexSchemaVersion)
    }

    /// A search with no intervening capture used to THROW against a deleted
    /// index (the read-only open fails). The read path heals the same way
    /// the capture path does, synchronously, and returns complete results.
    @Test func readAfterIndexDeletionRebuildsSynchronously() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.base) }

        _ = try fixture.ingestor.ingest(capture("gammamarker read path", offset: 0))
        try FileManager.default.removeItem(at: fixture.indexURL)

        let hits = try fixture.index.structuredSearch("gammamarker")
        let logged = codes(fixture.log)
        print("SELFHEAL_READ hits=\(hits.count) codes=\(logged)")
        #expect(hits.count == 1)
        #expect(logged.contains("index_missing_detected"))
    }

    /// A damaged file (its header overwritten) is not an index this build
    /// can trust: the integrity check catches it and the rebuild restores
    /// every row.
    @Test func corruptIndexIsDetectedOnTheReadPathAndRebuilt() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.base) }

        _ = try fixture.ingestor.ingest(capture("deltamarker one", offset: 0))
        _ = try fixture.ingestor.ingest(capture("deltamarker two", offset: 1))

        let handle = try FileHandle(forWritingTo: fixture.indexURL)
        try handle.seek(toOffset: 0)
        try handle.write(contentsOf: Data(repeating: 0x41, count: 100))
        try handle.close()

        let hits = try fixture.index.structuredSearch("deltamarker")
        let logged = codes(fixture.log)
        print("SELFHEAL_CORRUPT hits=\(hits.count) codes=\(logged) quick_check=\(fixture.index.quickCheck())")
        #expect(hits.count == 2)
        #expect(logged.contains("index_corrupt_detected"))
        #expect(logged.contains("index_rebuild_finished"))
        #expect(fixture.index.quickCheck())
    }

    /// Captures that arrive WHILE a rebuild is running are deferred too.
    /// The rebuild may already have scanned past them, so the deferrals are
    /// counted and another pass follows — otherwise those clips would be in
    /// the archive and never in the index.
    @Test func capturesDeferredDuringARebuildStillReachTheIndex() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.base) }

        _ = try fixture.ingestor.ingest(capture("zetamarker first", offset: 0))
        try FileManager.default.removeItem(at: fixture.indexURL)
        for offset in 1...4 {
            _ = try fixture.ingestor.ingest(capture("zetamarker burst \(offset)", offset: TimeInterval(offset)))
        }
        #expect(ClipboardDerivedIndex.waitForPendingRebuilds(forIndexAt: fixture.indexURL, timeout: 60))

        let hits = try fixture.index.structuredSearch("zetamarker")
        print("SELFHEAL_BURST hits=\(hits.count)")
        #expect(hits.count == 5)
    }

    /// The integrity probe answers three ways, and the difference matters:
    /// a database that cannot be ASKED is not a database that failed.
    @Test func integrityProbeSeparatesDamageFromASuccessfulRead() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.base) }
        _ = try fixture.ingestor.ingest(capture("etamarker", offset: 0))

        let healthy = fixture.index.integrityProbe()
        try Data(repeating: 0x42, count: 8_192).write(to: fixture.indexURL)
        let damaged = fixture.index.integrityProbe()
        print("SELFHEAL_PROBE healthy=\(healthy) damaged=\(damaged)")
        #expect(healthy == .readable(userVersion: ClipboardDerivedIndex.currentIndexSchemaVersion))
        #expect(damaged == .damaged)
    }

    /// Cost discipline: the integrity check is a full scan of the database,
    /// so it must run only when something OUTSIDE this process changed the
    /// file. A steady stream of captures re-stamps the cache and triggers no
    /// rebuild and no detection row at all.
    @Test func steadyCapturesNeverTriggerAnIntegrityRebuild() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.base) }

        for offset in 0..<6 {
            _ = try fixture.ingestor.ingest(capture("epsilonmarker \(offset)", offset: TimeInterval(offset)))
        }
        let logged = codes(fixture.log)
        let rebuilds = logged.filter { $0 == "index_rebuild_started" }.count
        print("SELFHEAL_STEADY codes=\(logged) rebuilds=\(rebuilds)")
        // One rebuild only: the very first capture, which had no index yet.
        #expect(rebuilds == 1)
        #expect(!logged.contains("index_corrupt_detected"))
        #expect(try fixture.index.structuredSearch("epsilonmarker").count == 6)

        // A prune or a delete writes to the index too. If those writers did
        // not re-stamp, the very next capture would pay a full-database
        // integrity check on the main thread — the stall this design forbids.
        let victim = try #require(try fixture.index.structuredSearch("epsilonmarker").first).id
        #expect(try fixture.index.delete(eventID: victim))
        #expect(try fixture.index.ensureSchema(mode: .capturePath) == .verified)
        let afterDelete = codes(fixture.log)
        print("SELFHEAL_STEADY_AFTER_DELETE codes=\(afterDelete)")
        #expect(afterDelete == logged)
    }
}
