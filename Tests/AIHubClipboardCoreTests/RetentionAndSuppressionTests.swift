import Foundation
import Testing
@testable import ClipboardArchiveCore

@Suite("Retention And Suppression")
struct RetentionAndSuppressionTests {
    // MARK: - Helpers (synthetic data only, temp roots only)

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("clipboard-retention-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func makeEvent(
        id: String,
        capturedAt: Date,
        content: String,
        privacyLabel: PrivacyLabel = .privateLocal
    ) -> StoredClipboardEvent {
        StoredClipboardEvent(
            id: id,
            capturedAt: capturedAt,
            contentType: .text,
            contentHash: "sha256:synthetic-\(id)",
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

    private func modificationDate(of url: URL) throws -> Date {
        let values = try url.resourceValues(forKeys: [.contentModificationDateKey])
        return values.contentModificationDate ?? Date.distantPast
    }

    private func ledgerEvents(archiveRoot: URL) throws -> [ClipboardDeletionEvent] {
        let root = archiveRoot.appendingPathComponent("deletion-ledger")
        guard FileManager.default.fileExists(atPath: root.path) else {
            return []
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let files = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "ndjson" }
        var events: [ClipboardDeletionEvent] = []
        for file in files {
            for line in try String(contentsOf: file).split(separator: "\n", omittingEmptySubsequences: true) {
                if let data = String(line).data(using: .utf8),
                   let event = try? decoder.decode(ClipboardDeletionEvent.self, from: data) {
                    events.append(event)
                }
            }
        }
        return events
    }

    // MARK: - Suppression parity (contract 6)

    @Test
    func testDoNotIndexEventIsHiddenEverywhereEvenWithoutLedgerRecord() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let indexURL = root.appendingPathComponent("index.sqlite")
        let base = ISO8601DateFormatter().date(from: "2026-07-20T12:00:00Z")!

        let visible = makeEvent(id: "evt-visible", capturedAt: base, content: "alpha synthetic keepable")
        let hidden = makeEvent(
            id: "evt-hidden-label",
            capturedAt: base.addingTimeInterval(60),
            content: "bravo synthetic hidden",
            privacyLabel: .doNotIndex
        )
        try appendEventLine(visible, archiveRoot: root)
        try appendEventLine(hidden, archiveRoot: root)

        // The hidden event is NOT in the deletion ledger; the label alone
        // must suppress it in every read surface.
        #expect(try ClipboardDeletionLedger(archiveRoot: root).deletedIDs().isEmpty)

        let recent = try ClipboardArchiveReader(archiveRoot: root)
            .recentItems(since: .distantPast, limit: 100)
        #expect(recent.map(\.id) == ["evt-visible"])

        let searcher = ClipboardArchiveSearcher(archiveRoot: root)
        #expect(try searcher.search(ClipboardSearchOptions(query: "bravo")).isEmpty)
        #expect(try searcher.search(ClipboardSearchOptions(query: "alpha")).count == 1)

        let indexedCount = try ClipboardDerivedIndex(archiveRoot: root, indexURL: indexURL).rebuild()
        #expect(indexedCount == 1)
        let ids = try runSQL(database: indexURL, sql: "SELECT id FROM clipboard_meta ORDER BY id;")
        #expect(ids == "evt-visible")
    }

    @Test
    func testLedgerRecordHidesEventEverywhereEvenWithoutDoNotIndexLabel() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let indexURL = root.appendingPathComponent("index.sqlite")
        let base = ISO8601DateFormatter().date(from: "2026-07-20T12:00:00Z")!

        let kept = makeEvent(id: "evt-kept", capturedAt: base, content: "charlie synthetic keepable")
        let tombstoned = makeEvent(
            id: "evt-hidden-ledger",
            capturedAt: base.addingTimeInterval(60),
            content: "delta synthetic hidden"
        )
        try appendEventLine(kept, archiveRoot: root)
        try appendEventLine(tombstoned, archiveRoot: root)

        // Ledger membership alone must suppress the event even though its
        // stored line still says private-local.
        try ClipboardDeletionLedger(archiveRoot: root)
            .recordDeletion(eventID: "evt-hidden-ledger", reason: "manual-delete")

        let recent = try ClipboardArchiveReader(archiveRoot: root)
            .recentItems(since: .distantPast, limit: 100)
        #expect(recent.map(\.id) == ["evt-kept"])

        let searcher = ClipboardArchiveSearcher(archiveRoot: root)
        #expect(try searcher.search(ClipboardSearchOptions(query: "delta")).isEmpty)
        #expect(try searcher.search(ClipboardSearchOptions(query: "charlie")).count == 1)

        let indexedCount = try ClipboardDerivedIndex(archiveRoot: root, indexURL: indexURL).rebuild()
        #expect(indexedCount == 1)
        let ids = try runSQL(database: indexURL, sql: "SELECT id FROM clipboard_meta ORDER BY id;")
        #expect(ids == "evt-kept")
    }

    // MARK: - Ledger read cache

    @Test
    func testLedgerCacheReturnsFreshIDsAfterExternalAppend() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let firstInstance = ClipboardDeletionLedger(archiveRoot: root)
        try firstInstance.recordDeletion(eventID: "ledger-id-one", reason: "manual-delete")
        #expect(try firstInstance.deletedIDs() == ["ledger-id-one"])

        // Append through a second ledger instance; the first instance's next
        // read must include the new id.
        let secondInstance = ClipboardDeletionLedger(archiveRoot: root)
        try secondInstance.recordDeletion(eventID: "ledger-id-two", reason: "manual-delete")
        #expect(try firstInstance.deletedIDs() == ["ledger-id-one", "ledger-id-two"])

        // Simulate a genuinely external process by appending raw bytes
        // directly to the ledger file, bypassing every in-process API. The
        // stat-based signature (size/mtime) must detect the change.
        let ledgerRoot = root.appendingPathComponent("deletion-ledger")
        let ledgerFile = try FileManager.default
            .contentsOfDirectory(at: ledgerRoot, includingPropertiesForKeys: nil)
            .first { $0.pathExtension == "ndjson" }
        let unwrappedLedgerFile = try #require(ledgerFile)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        var line = try encoder.encode(
            ClipboardDeletionEvent(clipboardEventID: "ledger-id-three", reason: "manual-delete")
        )
        line.append(0x0A)
        let handle = try FileHandle(forWritingTo: unwrappedLedgerFile)
        try handle.seekToEnd()
        try handle.write(contentsOf: line)
        try handle.close()

        #expect(try firstInstance.deletedIDs() == ["ledger-id-one", "ledger-id-two", "ledger-id-three"])
    }

    // MARK: - Incremental retention enforcement (contract 9)

    @Test
    func testEnforceRetentionLimitRedactsOldestOnlyAndSkipsFullRebuild() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let indexURL = root.appendingPathComponent("index.sqlite")
        let formatter = ISO8601DateFormatter()

        // Ten events across three day files. The five oldest all live in the
        // first day file, so enforcement must rewrite only that file.
        var eventIDs: [String] = []
        let days = [
            (day: "2026-07-01T10:00:00Z", count: 5),
            (day: "2026-07-02T10:00:00Z", count: 2),
            (day: "2026-07-03T10:00:00Z", count: 3)
        ]
        for (dayIndex, spec) in days.enumerated() {
            let dayBase = formatter.date(from: spec.day)!
            for slot in 0..<spec.count {
                let id = String(format: "evt-%d-%d", dayIndex, slot)
                eventIDs.append(id)
                try appendEventLine(
                    makeEvent(
                        id: id,
                        capturedAt: dayBase.addingTimeInterval(Double(slot) * 60),
                        content: "synthetic retention fixture \(id)"
                    ),
                    archiveRoot: root
                )
            }
        }
        let oldestFive = Array(eventIDs.prefix(5))
        let keptFive = Array(eventIDs.suffix(5))

        let index = ClipboardDerivedIndex(archiveRoot: root, indexURL: indexURL)
        #expect(try index.rebuild() == 10)
        // Sentinel row: a full index rebuild would erase it, per-event
        // deletes leave it in place.
        _ = try runSQL(
            database: indexURL,
            sql: "INSERT INTO clipboard_meta(id,captured_at,source_app,bundle_id,content_type,byte_count,raw_content_path) VALUES('sentinel-no-rebuild','','','','',0,'');"
        )

        let dayTwoFile = dayFileURL(for: formatter.date(from: days[1].day)!, archiveRoot: root)
        let dayThreeFile = dayFileURL(for: formatter.date(from: days[2].day)!, archiveRoot: root)
        let dayTwoBytesBefore = try Data(contentsOf: dayTwoFile)
        let dayThreeBytesBefore = try Data(contentsOf: dayThreeFile)

        let result = try ClipboardArchivePruner(archiveRoot: root, indexURL: indexURL)
            .enforceRetentionLimit(keepingMostRecent: 5)

        #expect(result.liveEvents == 10)
        #expect(result.prunedEvents == 5)
        #expect(result.changedFiles == 1)
        #expect(result.keptEvents == 5)

        // Exactly the five oldest were redacted, with retention-limit reason.
        let ledger = try ledgerEvents(archiveRoot: root)
        #expect(ledger.count == 5)
        #expect(Set(ledger.map(\.clipboardEventID)) == Set(oldestFive))
        #expect(ledger.allSatisfy { $0.reason == "retention-limit" })

        // The reader sees only the five newest.
        let recent = try ClipboardArchiveReader(archiveRoot: root)
            .recentItems(since: .distantPast, limit: 100)
        #expect(Set(recent.map(\.id)) == Set(keptFive))

        // Day files without overflow events are byte-identical.
        #expect(try Data(contentsOf: dayTwoFile) == dayTwoBytesBefore)
        #expect(try Data(contentsOf: dayThreeFile) == dayThreeBytesBefore)

        // Index: kept ids remain, overflow ids deleted, sentinel intact —
        // proving per-event deletes ran instead of a rebuild.
        let keptList = keptFive.map { "'\($0)'" }.joined(separator: ",")
        let oldestList = oldestFive.map { "'\($0)'" }.joined(separator: ",")
        #expect(try runSQL(
            database: indexURL,
            sql: "SELECT COUNT(*) FROM clipboard_meta WHERE id IN (\(keptList));"
        ) == "5")
        #expect(try runSQL(
            database: indexURL,
            sql: "SELECT COUNT(*) FROM clipboard_meta WHERE id IN (\(oldestList));"
        ) == "0")
        #expect(try runSQL(
            database: indexURL,
            sql: "SELECT COUNT(*) FROM clipboard_meta WHERE id = 'sentinel-no-rebuild';"
        ) == "1")
    }

    @Test
    func testEnforceRetentionLimitUnderLimitIsANoOp() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let indexURL = root.appendingPathComponent("index.sqlite")
        let base = ISO8601DateFormatter().date(from: "2026-07-20T09:00:00Z")!

        for slot in 0..<5 {
            try appendEventLine(
                makeEvent(
                    id: "evt-under-\(slot)",
                    capturedAt: base.addingTimeInterval(Double(slot) * 60),
                    content: "synthetic under-limit fixture \(slot)"
                ),
                archiveRoot: root
            )
        }
        let index = ClipboardDerivedIndex(archiveRoot: root, indexURL: indexURL)
        #expect(try index.rebuild() == 5)

        let dayFile = dayFileURL(for: base, archiveRoot: root)
        let dayBytesBefore = try Data(contentsOf: dayFile)
        let dayModifiedBefore = try modificationDate(of: dayFile)
        let indexBytesBefore = try Data(contentsOf: indexURL)
        let indexModifiedBefore = try modificationDate(of: indexURL)

        let result = try ClipboardArchivePruner(archiveRoot: root, indexURL: indexURL)
            .enforceRetentionLimit(keepingMostRecent: 10)

        #expect(result.liveEvents == 5)
        #expect(result.prunedEvents == 0)
        #expect(result.changedFiles == 0)
        #expect(result.deletedBodyFiles == 0)

        #expect(try Data(contentsOf: dayFile) == dayBytesBefore)
        #expect(try modificationDate(of: dayFile) == dayModifiedBefore)
        #expect(try Data(contentsOf: indexURL) == indexBytesBefore)
        #expect(try modificationDate(of: indexURL) == indexModifiedBefore)
        #expect(try ledgerEvents(archiveRoot: root).isEmpty)
    }

    @Test
    func testEnforceRetentionLimitTimingAtScale() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let indexURL = root.appendingPathComponent("index.sqlite")
        let base = ISO8601DateFormatter().date(from: "2026-07-10T00:00:00Z")!

        // 2,000 synthetic events written as one NDJSON payload.
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        var payload = Data()
        for slot in 0..<2_000 {
            let event = makeEvent(
                id: String(format: "evt-scale-%04d", slot),
                capturedAt: base.addingTimeInterval(Double(slot)),
                content: "synthetic scale fixture \(slot)"
            )
            payload.append(try encoder.encode(event))
            payload.append(0x0A)
        }
        let dayFile = dayFileURL(for: base, archiveRoot: root)
        try FileManager.default.createDirectory(
            at: dayFile.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try payload.write(to: dayFile)

        let index = ClipboardDerivedIndex(archiveRoot: root, indexURL: indexURL)
        #expect(try index.rebuild() == 2_000)

        let pruner = ClipboardArchivePruner(archiveRoot: root, indexURL: indexURL)

        let firstStart = Date()
        let firstResult = try pruner.enforceRetentionLimit(keepingMostRecent: 50)
        let firstDuration = Date().timeIntervalSince(firstStart)
        #expect(firstResult.liveEvents == 2_000)
        #expect(firstResult.prunedEvents == 1_950)
        #expect(firstResult.changedFiles == 1)
        // Loose bound to avoid CI flakes; the call is expected to finish in
        // well under a second on a healthy machine.
        #expect(firstDuration < 5.0)

        let secondStart = Date()
        let secondResult = try pruner.enforceRetentionLimit(keepingMostRecent: 50)
        let secondDuration = Date().timeIntervalSince(secondStart)
        #expect(secondResult.liveEvents == 50)
        #expect(secondResult.prunedEvents == 0)
        #expect(secondResult.changedFiles == 0)
        #expect(secondDuration < 5.0)

        #expect(try runSQL(database: indexURL, sql: "SELECT COUNT(*) FROM clipboard_meta;") == "50")
    }
}
