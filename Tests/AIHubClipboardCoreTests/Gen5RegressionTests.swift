import Darwin
import Foundation
import Testing
@testable import ClipboardArchiveCore

/// Regressions for the defects an independent first-pass review found in the
/// C1 repair packet, before it was committed. Each test names the wrong
/// behaviour it locks out, because a test whose name only says what it checks
/// cannot tell a later reader what it is defending.
@Suite("Gen5 review regressions")
struct Gen5RegressionTests {
    private func root() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("clipboard-gen5-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    // MARK: - A child's exit code is not its wait status

    /// `/usr/bin/false` exits 1. Before this, the raw `waitpid` status was
    /// handed to `sqliteFailed`, so the error read "sqlite3 failed with status
    /// 256" — in an error type whose every other site carries a real SQLite
    /// result code, making 5 either SQLITE_BUSY or death by SIGTRAP.
    @Test func childExitCodeIsReportedNotItsWaitStatus() throws {
        let base = try root()
        defer { try? FileManager.default.removeItem(at: base) }
        let input = base.appendingPathComponent("in.sql")
        try Data("select 1;\n".utf8).write(to: input)
        var caught: ClipboardDerivedIndexError?
        do {
            try ClipboardSQLiteProcess.run(
                executable: URL(fileURLWithPath: "/usr/bin/false"),
                database: base.appendingPathComponent("db.sqlite"),
                input: input, timeout: 5)
        } catch let error as ClipboardDerivedIndexError {
            caught = error
        }
        print("GEN5_ENTRY exit-code \(String(describing: caught))")
        #expect(caught == .sqliteFailed(1))
        #expect(caught != .sqliteFailed(256))
        #expect("\(caught!)" == "sqlite3 failed with status 1")
    }

    /// A child killed by a signal must not be mistaken for one that exited
    /// with that number, and must never look like success.
    @Test func childKilledBySignalIsAFailureAndIsDistinguishable() throws {
        let base = try root()
        defer { try? FileManager.default.removeItem(at: base) }
        let input = base.appendingPathComponent("in.sql")
        try Data("select 1;\n".utf8).write(to: input)
        let script = base.appendingPathComponent("suicide.sh")
        try Data("#!/bin/sh\nkill -TERM $$\n".utf8).write(to: script)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        // Catches ANY error, not just the expected type: a test that only
        // catches what it hopes for reports "nothing was thrown" when something
        // else was, which is the least useful failure message available.
        var caught: Error?
        do {
            try ClipboardSQLiteProcess.run(executable: script,
                database: base.appendingPathComponent("db.sqlite"),
                input: input, timeout: 5)
        } catch {
            caught = error
        }
        print("GEN5_ENTRY signal \(String(describing: caught))")
        #expect(caught as? ClipboardDerivedIndexError == .sqliteFailed(-Int32(SIGTERM)))
    }

    // MARK: - An index verdict is graded on index evidence

    /// The partition is the fix: `problems` is unchanged for `verify`, but an
    /// archive-side finding can no longer reach an index verdict. Before this,
    /// one unreferenced body file made `status` print `index: invalid` and name
    /// `repair-index`, which cannot fix an unreferenced body file.
    @Test func archiveFindingsAreNotIndexProblems() throws {
        let base = try root()
        defer { try? FileManager.default.removeItem(at: base) }
        var health = try ClipboardArchiveHealthReporter(
            archiveRoot: base, indexURL: base.appendingPathComponent("i.sqlite")).health()
        health.orphanedRichBodyFiles = 1
        health.insecureFiles = 2
        let verification = ClipboardVerification(
            health: health, eligibleEvents: 10, indexedEvents: 10,
            missingFromIndex: 0, extraInIndex: 0, indexIntegrityOK: true,
            indexExists: true, indexReadable: true, settingsReadable: true,
            pointerStatus: .absent)
        print("GEN5_ENTRY partition index=\(verification.indexProblems) archive=\(verification.archiveProblems)")
        #expect(verification.indexProblems.isEmpty)
        #expect(verification.archiveProblems.count == 2)
        // `verify` still sees exactly what it saw before, in the same order.
        #expect(verification.problems == verification.indexProblems + verification.archiveProblems)
        #expect(verification.exit == ClipboardCLIExit.integrity)
    }

    /// Membership gaps in the two directions are NOT the same problem. An
    /// event the index has not caught up with is what an in-flight capture
    /// looks like to two non-atomic scans; an index row the archive cannot
    /// account for cannot be produced by a capture at all.
    @Test func membershipGapsAreDistinguishedByDirection() throws {
        let base = try root()
        defer { try? FileManager.default.removeItem(at: base) }
        let health = try ClipboardArchiveHealthReporter(
            archiveRoot: base, indexURL: base.appendingPathComponent("i.sqlite")).health()
        func verification(missing: Int, extra: Int) -> ClipboardVerification {
            ClipboardVerification(
                health: health, eligibleEvents: 10, indexedEvents: 10,
                missingFromIndex: missing, extraInIndex: extra, indexIntegrityOK: true,
                indexExists: true, indexReadable: true, settingsReadable: true,
                pointerStatus: .absent)
        }
        let behind = verification(missing: 1, extra: 0)
        let inconsistent = verification(missing: 0, extra: 1)
        print("GEN5_ENTRY membership behind=\(behind.indexProblems) inconsistent=\(inconsistent.indexProblems)")
        #expect(behind.indexProblems.count == 1)
        #expect(behind.indexProblems[0].contains("missing from the search index"))
        #expect(inconsistent.indexProblems.count == 1)
        #expect(inconsistent.indexProblems[0].contains("no longer has"))
    }

    // MARK: - A corrupt failure ledger heals on a new failure, never on a success

    /// Before this, one undecodable byte wedged the ledger permanently:
    /// `read()` returned nil forever, every `update(add:)` returned false, and
    /// `status` warned `failure_state_unreadable` for the life of the machine
    /// with no remedy and no later failure ever recorded.
    @Test func aNewFailureHealsAnUndecodableLedgerButASuccessCannot() throws {
        let base = try root()
        defer { try? FileManager.default.removeItem(at: base) }
        let logs = base.appendingPathComponent("Logs")
        try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
        let state = ClipboardFailureState(logDirectory: logs)
        try Data("{ not json".utf8).write(to: state.url)

        // A success must NOT clear failures it cannot read.
        #expect(state.update(remove: ["capture_failed"]) == false)
        #expect(state.read() == nil)
        let quarantinesAfterRemove = try FileManager.default
            .contentsOfDirectory(atPath: base.path).filter { $0.contains(".corrupt-") }
        #expect(quarantinesAfterRemove.isEmpty)

        // A new failure is strictly more information than an unreadable file,
        // so it heals: bad bytes set aside once, ledger continues from empty.
        #expect(state.update(add: "capture_failed") == true)
        let healed = state.read()
        print("GEN5_ENTRY ledger healed=\(String(describing: healed?.keys.sorted()))")
        #expect(healed?.keys.sorted() == ["capture_failed"])
        let quarantines = try FileManager.default
            .contentsOfDirectory(atPath: base.path).filter { $0.contains(".corrupt-") }
        #expect(quarantines.count == 1)
        #expect(try Data(contentsOf: base.appendingPathComponent(quarantines[0]))
                == Data("{ not json".utf8))
    }

    // MARK: - Reading text fast must not stop reading text that still works

    /// The UTF-8 fast path is 11.4x quicker on a real archive, but the
    /// sniffing initialiser it replaces SUCCEEDS on files that are not valid
    /// UTF-8. Without the fallback this change would turn a readable legacy or
    /// imported archive file into a throw — correctness traded for speed. This
    /// test exists so the fallback cannot be tidied away as dead code.
    @Test func aLegacyNonUTF8FileIsStillReadable() throws {
        let base = try root()
        defer { try? FileManager.default.removeItem(at: base) }
        let url = base.appendingPathComponent("legacy.ndjson")
        let text = "legacy-utf16-line\n"
        // UTF-16 with a byte-order mark: sniffing resolves it confidently,
        // strict UTF-8 cannot decode it at all.
        try Data(text.utf16.flatMap { [UInt8($0 & 0xFF), UInt8($0 >> 8)] }
                 .withUnsafeBufferPointer { Array([0xFF, 0xFE] + $0) })
            .write(to: url)
        #expect((try? String(contentsOf: url, encoding: .utf8)) == nil)
        let read = try String.readingClipboardText(contentsOf: url)
        print("GEN5_ENTRY legacy-read \(read.count) char(s)")
        #expect(read == text)
    }

    /// And the ordinary case still takes the fast path and round-trips.
    @Test func anOrdinaryUTF8FileRoundTrips() throws {
        let base = try root()
        defer { try? FileManager.default.removeItem(at: base) }
        let url = base.appendingPathComponent("ordinary.ndjson")
        let text = "ordinary-line-with-accents-café\n"
        try Data(text.utf8).write(to: url)
        #expect(try String.readingClipboardText(contentsOf: url) == text)
    }

    // MARK: - A failed rebuild is not retried on every capture

    /// Serialising alone is not a failure policy: with no backoff, every
    /// capture after a failed rebuild arms another one that burns the whole
    /// sqlite deadline and fails identically, forever, unattended.
    @Test func aFailedRebuildBacksOffBeforeItIsRetried() {
        let cache = ClipboardDerivedIndex.VerifiedSchemaCache()
        let path = "/tmp/clipboard-gen5-backoff-\(UUID().uuidString).sqlite"
        #expect(cache.rebuildIsBackedOff(path) == false)
        cache.noteRebuildFailure(path)
        print("GEN5_ENTRY backoff armed")
        #expect(cache.rebuildIsBackedOff(path) == true)
        cache.noteRebuildSuccess(path)
        #expect(cache.rebuildIsBackedOff(path) == false)
    }
}
