import Darwin
import Foundation
import Testing
@testable import ClipboardArchiveCore

@Suite("Content-free operational logging")
struct ClipboardOperationalLogTests {
    private func scratch() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("operational-test-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func permissions(_ url: URL) throws -> Int? {
        (try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber)?
            .intValue
    }

    /// Rotation keeps exactly the retained set, drops the
    /// oldest, holds 0700/0600, and every surviving row decodes with the
    /// documented key set.
    @Test func rotationPermissionsAndFixedSchema() throws {
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let log = ClipboardOperationalLog(
            directory: root.appendingPathComponent("Logs", isDirectory: true),
            maximumFileBytes: 4096,
            retainedFiles: 5
        )
        for beat in 0..<3_000 {
            #expect(log.record(.heartbeat, count: beat, polls: beat, captures: 1, rssBytes: 4096))
        }

        let present = try FileManager.default
            .contentsOfDirectory(at: log.directory, includingPropertiesForKeys: nil)
            .map(\.lastPathComponent)
            .filter { $0.hasSuffix(".ndjson") }
            .sorted()
        #expect(present == [
            "operational.1.ndjson", "operational.2.ndjson", "operational.3.ndjson",
            "operational.4.ndjson", "operational.ndjson"
        ])
        #expect(try permissions(log.directory) == 0o700)

        var rows = 0
        var oldestCount = Int.max
        for name in present {
            let url = log.directory.appendingPathComponent(name)
            #expect(try permissions(url) == 0o600)
            let data = try Data(contentsOf: url)
            #expect(data.count <= 4096)
            for line in data.split(separator: 10) {
                let row = try #require(JSONSerialization.jsonObject(with: Data(line)) as? [String: Any])
                #expect(row.keys.sorted() == ClipboardOperationalLog.rowFields)
                oldestCount = min(oldestCount, row["count"] as? Int ?? Int.max)
                rows += 1
            }
        }
        print("OPLOG_ROTATION rows_decoded=\(rows) files=\(present.count) oldest_count_field=\(oldestCount)")
        #expect(rows > 0)
        // The first rows are gone: rotation dropped them rather than
        // growing the log past its cap.
        #expect(oldestCount > 0)
    }

    /// A heartbeat row carries the three liveness numbers.
    @Test func heartbeatCarriesLivenessNumbers() throws {
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let log = ClipboardOperationalLog(directory: root.appendingPathComponent("Logs", isDirectory: true))
        #expect(ClipboardProcessMetrics.residentSetBytes() > 0)
        #expect(log.record(
            .heartbeat,
            durationMs: 1_500,
            polls: 9_000,
            captures: 4,
            rssBytes: ClipboardProcessMetrics.residentSetBytes()
        ))
        let entry = try #require(log.read(limit: 1).first)
        #expect(entry.code == "heartbeat")
        #expect(entry.level == "info")
        #expect(entry.component == "app")
        #expect((entry.numbers["polls"] ?? 0) == 9_000)
        #expect((entry.numbers["captures"] ?? 0) == 4)
        #expect((entry.numbers["rssBytes"] ?? 0) > 0)
        #expect((entry.numbers["pid"] ?? 0) == Double(getpid()))
        print("OPLOG_HEARTBEAT \(entry.textDescription)")
    }

    /// A stopped poll timer is a heartbeat that says zero — the renderer
    /// must not suppress it as an uninteresting number.
    @Test func aZeroPollHeartbeatStillShowsItsZero() throws {
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let log = ClipboardOperationalLog(directory: root.appendingPathComponent("Logs", isDirectory: true))
        #expect(log.record(.heartbeat, polls: 0, captures: 0, rssBytes: 4096))
        let line = try #require(log.read(limit: 1).first).textDescription
        #expect(line.contains("polls=0"))
        #expect(line.contains("captures=0"))
        // Fields that are noise for this code stay suppressed.
        #expect(!line.contains("errno="))
        print("OPLOG_DEAD_TIMER \(line)")
    }

    /// Codes carry a fixed component and level, and the verb stays closed.
    @Test func codesAndVerbsStayClosed() throws {
        #expect(ClipboardOperationalLog.Code.captureFailed.component == .capture)
        #expect(ClipboardOperationalLog.Code.captureFailed.defaultLevel == .error)
        #expect(ClipboardOperationalLog.Code.cliCommand.component == .cli)
        #expect(ClipboardOperationalLog.Verb(command: "repair-index") == .repairIndex)
        #expect(ClipboardOperationalLog.Verb(command: "not-a-verb") == .unknown)
        #expect(ClipboardOperationalLog.Verb(command: "") == .unknown)
        #expect(ClipboardCaptureFailure.diskFull.posixCode == ENOSPC)
        #expect(ClipboardCaptureFailure.permissionDenied.posixCode == EACCES)
        #expect(ClipboardCaptureFailure.other.posixCode == 0)
    }

    /// `--tail`, `--errors` and `--since` filter the rotated set.
    @Test func readerTailsFiltersAndOrders() throws {
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let log = ClipboardOperationalLog(
            directory: root.appendingPathComponent("Logs", isDirectory: true),
            maximumFileBytes: 1024,
            retainedFiles: 3
        )
        let before = Date()
        for _ in 0..<20 {
            #expect(log.record(.appStart))
        }
        #expect(log.record(.indexRebuildFailed, durationMs: 12))
        #expect(log.read(limit: 3).count == 3)
        #expect(log.read(limit: 500).last?.code == "index_rebuild_failed")
        let errors = log.read(limit: 500, errorsOnly: true)
        #expect(errors.count == 1)
        #expect(errors.first?.code == "index_rebuild_failed")
        #expect(log.read(limit: 500, since: before).isEmpty == false)
        #expect(log.read(limit: 500, since: Date().addingTimeInterval(60)).isEmpty)
        // Oldest-first across the rotated set, not just within one file.
        let ordered = log.read(limit: 500)
        #expect(ordered.count > 3)
        #expect(zip(ordered, ordered.dropFirst()).allSatisfy {
            ($0.timestamp ?? .distantPast) <= ($1.timestamp ?? .distantPast)
        })
    }

    /// The isolation rule itself: an injected application-support root
    /// moves the log, and only the absence of one reaches the user's real
    /// log folder.
    @Test func logDirectoryFollowsAnInjectedSupportRoot() throws {
        let injected = ClipboardDefaults.logDirectory(
            environment: [ClipboardDefaults.applicationSupportEnvironmentKey: "/tmp/isolated-root"]
        )
        #expect(injected.path == "/tmp/isolated-root/Logs")
        #expect(ClipboardStoreLocator.resolve(
            environment: [ClipboardDefaults.applicationSupportEnvironmentKey: "/tmp/isolated-root"]
        ).logDirectory.path == "/tmp/isolated-root/Logs")
        let standard = ClipboardDefaults.logDirectory(environment: [:])
        #expect(standard.path.hasSuffix("/Library/Logs/ClipboardArchive"))
        #expect(standard.path != injected.path)
    }

    /// The refactor that moved the appender out of the usage log must not
    /// have changed one byte of its output. The expected row was captured
    /// from the pre-refactor build; only the timestamp varies.
    @Test func usageRowBytesAreUnchangedByTheSharedAppender() throws {
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let log = ClipboardUsageLog(archiveRoot: root)
        #expect(log.record(.capture, outcome: .excluded, scope: .index, count: 7, durationMs: 12.5, bytes: 33))
        let line = try String(contentsOf: root.appendingPathComponent("usage/events.ndjson"), encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let normalized = line.replacingOccurrences(
            of: "\"timestamp\":\"[^\"]+\"",
            with: "\"timestamp\":\"<t>\"",
            options: .regularExpression
        )
        #expect(normalized == "{\"build\":0,\"bytes\":33,\"count\":7,\"durationMs\":12.5,"
            + "\"event\":\"capture\",\"outcome\":\"excluded\",\"schema\":1,\"scope\":\"index\","
            + "\"timestamp\":\"<t>\",\"version\":[]}")
        #expect(line.range(
            of: "\"timestamp\":\"[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}\\.[0-9]{3}Z\"",
            options: .regularExpression
        ) != nil)
        print("OPLOG_USAGE_ROW \(normalized)")
    }

    /// A settings read that fell back to defaults says why — defaults are
    /// not the user's retention choice.
    @Test func settingsFallbackReportsItsReason() throws {
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("settings.json")
        let store = ClipboardSettingsStore(settingsURL: url)
        #expect(store.loadReporting().fallback == .missing)
        try Data("{ not json".utf8).write(to: url)
        #expect(store.loadReporting().fallback == .corrupt)
        var saved = ClipboardSettings()
        saved.retentionMode = .unlimited
        try store.save(saved)
        let reloaded = store.loadReporting()
        #expect(reloaded.fallback == nil)
        #expect(reloaded.settings.retentionMode == .unlimited)
        #expect(store.load().retentionMode == .unlimited)
    }

    /// Planted-marker control with its known positive: a capture whose body
    /// is a marker must leave the marker out of BOTH logs, while the
    /// failure it caused is recorded by class.
    @Test func plantedMarkerNeverReachesEitherLog() throws {
        let root = try scratch()
        defer {
            let raw = root.appendingPathComponent("raw")
            try? FileManager.default.setAttributes(
                [.posixPermissions: NSNumber(value: Int16(0o700))],
                ofItemAtPath: raw.path
            )
            // These are year folders. Without the execute bit they cannot
            // be entered, and the scratch tree was left behind on every run.
            for name in (try? FileManager.default.contentsOfDirectory(atPath: raw.path)) ?? [] {
                try? FileManager.default.setAttributes(
                    [.posixPermissions: NSNumber(value: Int16(0o700))],
                    ofItemAtPath: raw.appendingPathComponent(name).path
                )
            }
            try? FileManager.default.removeItem(at: root)
        }
        let logDirectory = root.appendingPathComponent("Logs", isDirectory: true)
        let log = ClipboardOperationalLog(directory: logDirectory)
        let index = ClipboardDerivedIndex(
            archiveRoot: root,
            indexURL: root.appendingPathComponent("index.sqlite"),
            operationalLog: log
        )
        let ingestor = ClipboardIngestor(
            archiveWriter: ClipboardArchiveWriter(archiveRoot: root),
            derivedIndex: index,
            operationalLog: log
        )
        let marker = "CLIPBOARD_H4_MARKER_\(UUID().uuidString)"

        // (a) writable archive: the capture is stored.
        _ = try ingestor.ingest(ClipboardCapture(
            content: marker,
            sourceApp: ClipboardSourceApp(name: "Synthetic")
        ))
        _ = try index.rebuild()

        // (b) unwritable raw/ AND day file: the same content now fails by
        // permission class. (The day file's own mode matters: an append to
        // an existing file succeeds through a read-only directory.)
        let rawDirectory = root.appendingPathComponent("raw")
        for name in try FileManager.default.contentsOfDirectory(atPath: rawDirectory.path) {
            try FileManager.default.setAttributes(
                [.posixPermissions: NSNumber(value: Int16(0o400))],
                ofItemAtPath: rawDirectory.appendingPathComponent(name).path
            )
        }
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: Int16(0o500))],
            ofItemAtPath: rawDirectory.path
        )
        #expect(throws: (any Error).self) {
            try ingestor.ingest(ClipboardCapture(
                content: "\(marker) second attempt",
                sourceApp: ClipboardSourceApp(name: "Synthetic")
            ))
        }

        let operational = try String(
            contentsOf: logDirectory.appendingPathComponent("operational.ndjson"),
            encoding: .utf8
        )
        let usage = try String(
            contentsOf: root.appendingPathComponent("usage/events.ndjson"),
            encoding: .utf8
        )
        #expect(!operational.contains(marker))
        #expect(!usage.contains(marker))
        // Known-positive controls: the run DID produce the rows whose
        // absence would make the grep vacuous.
        let codes = log.read(limit: 500).map(\.code)
        #expect(codes.contains("capture_failed"))
        #expect(codes.contains("index_rebuild_finished"))
        let failure = try #require(log.read(limit: 500).last { $0.code == "capture_failed" })
        #expect(failure.numbers["errno"] == Double(EACCES))
        #expect(failure.level == "error")
        print("OPLOG_MARKER_CONTROL capture_failed=\(codes.filter { $0 == "capture_failed" }.count)"
            + " rebuild_finished=\(codes.filter { $0 == "index_rebuild_finished" }.count)")
    }

    /// An index whose upsert cannot run leaves the event stored and the
    /// failure recorded.
    @Test func indexUpsertFailureIsRecorded() throws {
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let log = ClipboardOperationalLog(directory: root.appendingPathComponent("Logs", isDirectory: true))
        let broken = ClipboardDerivedIndex(
            archiveRoot: root,
            indexURL: root.appendingPathComponent("broken.sqlite"),
            sqliteExecutableURL: URL(fileURLWithPath: "/usr/bin/false"),
            operationalLog: log
        )
        let result = try ClipboardIngestor(
            archiveWriter: ClipboardArchiveWriter(archiveRoot: root),
            derivedIndex: broken,
            operationalLog: log
        ).ingest(ClipboardCapture(
            content: "safe synthetic fixture",
            sourceApp: ClipboardSourceApp(name: "Synthetic")
        ))
        guard case let .stored(_, indexUpdate) = result else {
            Issue.record("ingest did not store the event")
            return
        }
        #expect(indexUpdate == .failed)
        #expect(log.read(limit: 50).contains { $0.code == "index_upsert_failed" })
    }

    /// Nothing is logged until a surface hands over a destination.
    @Test func silentWithoutAnInjectedLog() throws {
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let index = ClipboardDerivedIndex(
            archiveRoot: root,
            indexURL: root.appendingPathComponent("index.sqlite")
        )
        _ = try ClipboardIngestor(
            archiveWriter: ClipboardArchiveWriter(archiveRoot: root),
            derivedIndex: index
        ).ingest(ClipboardCapture(
            content: "safe synthetic fixture",
            sourceApp: ClipboardSourceApp(name: "Synthetic")
        ))
        _ = try index.rebuild()
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("Logs").path))
    }
}
