import Darwin
import Foundation
import Testing
@testable import ClipboardArchiveCore

@Suite("C1 operational regressions")
struct C1RegressionTests {
    func root() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("clipboard-c1-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test func preferencesArePrivateFilesAndIndependent() throws {
        let first = try root(), second = try root()
        defer { try? FileManager.default.removeItem(at: first); try? FileManager.default.removeItem(at: second) }
        let a = ClipboardPreferences(environment: [ClipboardDefaults.applicationSupportEnvironmentKey: first.path])
        let b = ClipboardPreferences(environment: [ClipboardDefaults.applicationSupportEnvironmentKey: second.path])
        a.set(true, forKey: "capturePaused")
        print("C1_ENTRY preferences")
        #expect(a.bool(forKey: "capturePaused"))
        #expect(!b.bool(forKey: "capturePaused"))
        #expect(FileManager.default.fileExists(atPath: first.appendingPathComponent("preferences.json").path))
    }

    @Test func incompleteAndOutOfRangeSettingsRetainChoices() throws {
        let base = try root(); defer { try? FileManager.default.removeItem(at: base) }
        let store = ClipboardSettingsStore(settingsURL: base.appendingPathComponent("settings.json"))
        let chosen = ClipboardSettings(archiveEnabled: false, retentionMode: .unlimited)
        try store.save(chosen)
        for bytes in ["{}", "{\"archiveEnabled\":true}", "{\"archiveEnabled\":false,\"recentItemLimit\":0}"] {
            try Data(bytes.utf8).write(to: store.settingsURL)
            let result = store.loadReporting(readOnly: true)
            print("C1_ENTRY settings fallback=\(result.fallback?.rawValue ?? "none")")
            #expect(result.fallback == .lastGoodUsed)
            #expect(result.settings == chosen)
            #expect(try String(contentsOf: store.settingsURL, encoding: .utf8) == bytes)
        }
    }

    @Test func heartbeatProgressAndClockAreGraded() {
        var facts = ClipboardStatusFacts(storesPresent: true, appRunning: true, captureEnabled: true,
            heartbeatAge: 0, lastCaptureAge: nil, errorsLastDay: 0, indexState: .fresh,
            pollsSinceLastHeartbeat: 0)
        print("C1_ENTRY heartbeat")
        #expect(!ClipboardStatusRules.verdict(facts).isHealthy)
        facts.pollsSinceLastHeartbeat = 3
        #expect(ClipboardStatusRules.verdict(facts).isHealthy)
        facts.heartbeatAge = -90 * 86_400
        #expect(!ClipboardStatusRules.verdict(facts).isHealthy)
        facts.heartbeatAge = 0
        facts.pollsSinceLastHeartbeat = 0
        facts.startupAge = 20
        #expect(ClipboardStatusRules.verdict(facts).isHealthy)
        // REVERSED for CA-C2-01. This line asserted that a suspended capture
        // reads healthy, which is the defect cycle 2 filed: a pause disarms
        // every check above it, so a machine paused years out answered exit 0
        // with an empty warning list while nothing was being archived. A
        // suspension is now REPORTED rather than skipped. The rest of this
        // test is unchanged.
        facts.startupAge = nil; facts.captureSuspended = true
        let suspended = ClipboardStatusRules.verdict(facts)
        #expect(!suspended.isHealthy)
        #expect(suspended.warnings.contains { $0.contains("paused") })
    }

    @Test func logLossCannotClearFailuresAndRecoveryIsScoped() throws {
        let base = try root(); defer { try? FileManager.default.removeItem(at: base) }
        let logs = base.appendingPathComponent("Logs")
        let log = ClipboardOperationalLog(directory: logs)
        log.record(.captureFailed, errno: ENOSPC)
        log.record(.indexRebuildFailed)
        try FileManager.default.removeItem(at: logs)
        print("C1_ENTRY logloss")
        #expect(log.unresolvedFailures.contains("capture_failed"))
        log.recoverCaptureFailure()
        #expect(!log.unresolvedFailures.contains("capture_failed"))
        #expect(log.unresolvedFailures.contains("index_rebuild_failed"))
        log.record(.indexRebuildFinished)
        #expect(log.unresolvedFailures.isEmpty)
        try FileManager.default.removeItem(at: logs)
        try Data("blocked".utf8).write(to: logs)
        #expect(!log.record(.captureFailed))
        #expect(log.unresolvedFailures.contains("capture_failed"))
        #expect(!log.sinkReadable)
    }

    @Test func markerFailurePrecedesEventCommit() throws {
        let base = try root(); defer { try? FileManager.default.removeItem(at: base) }
        let writer = ClipboardArchiveWriter(archiveRoot: base)
        let capture = ClipboardCapture(content: "synthetic marker regression", sourceApp: ClipboardSourceApp(name: "Test"))
        _ = try writer.archiveAllowedCapture(capture)
        try FileManager.default.removeItem(at: base.appendingPathComponent("archive-format.json"))
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: base.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: base.path) }
        print("C1_ENTRY marker")
        #expect(throws: (any Error).self) { try writer.archiveAllowedCapture(capture) }
        #expect(try ClipboardArchiveReader(archiveRoot: base).recentItems(since: .distantPast, limit: 10).count == 1)
    }

    @Test func sqliteTimeoutPreservesIndexAndKillsGroup() throws {
        let base = try root(); defer { try? FileManager.default.removeItem(at: base) }
        let archive = base.appendingPathComponent("archive")
        let indexURL = base.appendingPathComponent("index.sqlite")
        try FileManager.default.createDirectory(at: archive, withIntermediateDirectories: true)
        let index = ClipboardDerivedIndex(archiveRoot: archive, indexURL: indexURL)
        _ = try index.rebuild()
        let before = try Data(contentsOf: indexURL)
        let stub = base.appendingPathComponent("stub.sh"), marker = base.appendingPathComponent("entered")
        try Data("#!/bin/sh\necho $$ > '\(marker.path)'\nsleep 60\n".utf8).write(to: stub)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: stub.path)
        var broken = index; broken.sqliteExecutableURL = stub; broken.sqliteTimeoutSeconds = 0.75
        let start = ProcessInfo.processInfo.systemUptime
        do {
            _ = try broken.rebuild()
            Issue.record("SQLite timeout unexpectedly succeeded")
        } catch {
            #expect((error as? POSIXError)?.code == .ETIMEDOUT)
        }
        print("C1_ENTRY timeout")
        #expect(ProcessInfo.processInfo.systemUptime - start < 2)
        #expect(try Data(contentsOf: indexURL) == before)
        let pid = try #require(Int32(String(contentsOf: marker, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)))
        #expect(kill(pid, 0) == -1)
        #expect(errno == ESRCH)
        let reapDeadline = ProcessInfo.processInfo.systemUptime + 1
        while kill(-pid, 0) == 0 && ProcessInfo.processInfo.systemUptime < reapDeadline { usleep(10_000) }
        #expect(kill(-pid, 0) == -1)
    }
}
