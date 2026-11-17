import Darwin
import Foundation
import Testing
@testable import ClipboardArchiveCore

/// Append durability for the NDJSON day file: a tail torn by a kill or a
/// full disk must cost at most the row that was being written, never the
/// row before it and never half a row afterwards. Synthetic data only,
/// temporary roots only.
@Suite("Archive append integrity")
struct ArchiveAppendIntegrityTests {
    private func temporaryRoot() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("clipboard-append-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    private func dayFileURL(root: URL, capturedAt: Date) -> URL {
        let day = Self.dayFormatter.string(from: capturedAt)
        return root
            .appendingPathComponent("raw")
            .appendingPathComponent(String(day.prefix(4)))
            .appendingPathComponent(String(day.dropFirst(5).prefix(2)))
            .appendingPathComponent("\(day)_clipboard-events.ndjson")
    }

    private func capture(_ content: String, at capturedAt: Date) -> ClipboardCapture {
        ClipboardCapture(
            capturedAt: capturedAt,
            content: content,
            sourceApp: ClipboardSourceApp(name: "Append Test", bundleIdentifier: "test.append"),
            pasteboardTypes: ["public.utf8-plain-text"]
        )
    }

    /// Decodes a day file: how many lines parse as stored events, how many
    /// do not, and the inline bodies of the ones that do.
    private func scan(_ url: URL) throws -> (stored: [String], invalid: Int) {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        var stored: [String] = []
        var invalid = 0
        let text = try String(contentsOf: url, encoding: .utf8)
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let data = String(line).data(using: .utf8) else {
                invalid += 1
                continue
            }
            if let event = try? decoder.decode(StoredClipboardEvent.self, from: data) {
                stored.append(event.contentInline ?? "")
            } else if (try? JSONDecoder().decode(BlockedClipboardEvent.self, from: data)) != nil {
                continue
            } else {
                invalid += 1
            }
        }
        return (stored, invalid)
    }

    /// A day file whose last row lost its terminator (a kill between the row
    /// bytes and the newline) must not swallow the next row: the boundary is
    /// restored first, so the old row AND the new row both decode.
    @Test func appendAfterMissingTerminatorKeepsBothRows() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let capturedAt = Date(timeIntervalSince1970: 1_800_000_000)
        var writer = ClipboardArchiveWriter(archiveRoot: root)

        _ = try writer.archiveAllowedCapture(capture("first row body", at: capturedAt))
        let url = dayFileURL(root: root, capturedAt: capturedAt)
        // Tear the tail exactly as a kill between the bytes and the
        // terminator would: drop the trailing newline, keep the row whole.
        var bytes = try Data(contentsOf: url)
        #expect(bytes.last == 0x0A)
        bytes.removeLast()
        try bytes.write(to: url)

        var repairedRows = 0
        let log = ClipboardOperationalLog(directory: root.appendingPathComponent("Logs", isDirectory: true))
        writer.operationalLog = log
        _ = try writer.archiveAllowedCapture(capture("second row body", at: capturedAt.addingTimeInterval(1)))

        let result = try scan(url)
        repairedRows = log.read(limit: 50).filter { $0.code == "archive_tail_repaired" }.count
        let health = try ClipboardArchiveHealthReporter(
            archiveRoot: root,
            indexURL: root.appendingPathComponent("unused-index.sqlite")
        ).health()
        print("APPEND_TORN_TAIL stored=\(result.stored) invalid=\(result.invalid) health_invalid=\(health.invalidJSONLines) repaired_rows=\(repairedRows)")
        #expect(result.stored == ["first row body", "second row body"])
        #expect(result.invalid == 0)
        #expect(health.invalidJSONLines == 0)
        #expect(repairedRows == 1)
    }

    /// A half-written row (the kill landed mid-bytes) can never be healed
    /// into a valid row — but it must cost exactly ONE invalid line, not
    /// two, and the next row must decode.
    @Test func appendAfterHalfWrittenRowLosesOnlyThatRow() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let capturedAt = Date(timeIntervalSince1970: 1_800_000_000)
        var writer = ClipboardArchiveWriter(archiveRoot: root)

        _ = try writer.archiveAllowedCapture(capture("intact row body", at: capturedAt))
        let url = dayFileURL(root: root, capturedAt: capturedAt)
        // Append a torn fragment: a half JSON object with no terminator.
        var bytes = try Data(contentsOf: url)
        bytes.append(Data(#"{"capturedAt":"2027-01-01T00:00:00Z","contentInl"#.utf8))
        try bytes.write(to: url)

        _ = try writer.archiveAllowedCapture(capture("row after fragment", at: capturedAt.addingTimeInterval(1)))

        let result = try scan(url)
        print("APPEND_HALF_ROW stored=\(result.stored) invalid=\(result.invalid)")
        #expect(result.stored == ["intact row body", "row after fragment"])
        #expect(result.invalid == 1)
    }

    /// A write that fails partway (ENOSPC, a killed volume) must leave the
    /// file exactly as it was: no partial row, and an error carrying the
    /// errno so the capture path can classify it.
    @Test func shortWriteLeavesFileUnchangedAndThrowsErrno() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let capturedAt = Date(timeIntervalSince1970: 1_800_000_000)
        var writer = ClipboardArchiveWriter(archiveRoot: root)

        _ = try writer.archiveAllowedCapture(capture("row before the fault", at: capturedAt))
        let url = dayFileURL(root: root, capturedAt: capturedAt)
        let sizeBefore = try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int ?? -1

        writer.appendFault = ClipboardArchiveWriter.AppendFault(bytesBeforeFailure: 32, errnoValue: ENOSPC)
        var thrown: Error?
        do {
            _ = try writer.archiveAllowedCapture(capture("row that must not survive", at: capturedAt.addingTimeInterval(1)))
        } catch {
            thrown = error
        }
        let sizeAfter = try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int ?? -1
        let appendError = thrown as? ClipboardArchiveAppendError
        let classified = thrown.map { ClipboardCaptureFailure.classify($0) }
        let result = try scan(url)
        print("APPEND_SHORT_WRITE size_before=\(sizeBefore) size_after=\(sizeAfter) errno=\(appendError?.errnoValue ?? -1) class=\(classified?.rawValue ?? "none") stored=\(result.stored.count) invalid=\(result.invalid)")
        #expect(sizeAfter == sizeBefore)
        #expect(appendError?.errnoValue == ENOSPC)
        #expect(classified == .diskFull)
        #expect(result.stored == ["row before the fault"])
        #expect(result.invalid == 0)
    }

    /// The failed append leaves no orphaned body file either, and the next
    /// healthy append still lands on a clean boundary.
    @Test func appendRecoversAfterAFaultedWrite() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let capturedAt = Date(timeIntervalSince1970: 1_800_000_000)
        var writer = ClipboardArchiveWriter(archiveRoot: root, inlineContentLimitBytes: 16)

        _ = try writer.archiveAllowedCapture(capture("first", at: capturedAt))
        writer.appendFault = ClipboardArchiveWriter.AppendFault(bytesBeforeFailure: 16, errnoValue: ENOSPC)
        let oversized = String(repeating: "b", count: 256)
        #expect(throws: ClipboardArchiveAppendError.self) {
            _ = try writer.archiveAllowedCapture(capture(oversized, at: capturedAt.addingTimeInterval(1)))
        }
        writer.appendFault = nil
        _ = try writer.archiveAllowedCapture(capture("third", at: capturedAt.addingTimeInterval(2)))

        let url = dayFileURL(root: root, capturedAt: capturedAt)
        let result = try scan(url)
        let health = try ClipboardArchiveHealthReporter(
            archiveRoot: root,
            indexURL: root.appendingPathComponent("unused-index.sqlite")
        ).health()
        print("APPEND_RECOVERY stored=\(result.stored) invalid=\(result.invalid) missing_bodies=\(health.missingBodyFiles) large_bodies=\(health.largeBodyFiles)")
        #expect(result.stored == ["first", "third"])
        #expect(result.invalid == 0)
        #expect(health.largeBodyFiles == 0)
    }

    /// The typed append error classifies through the existing POSIX chain,
    /// so the capture path reports "Disk full" rather than "Write failed".
    @Test func appendErrorClassifiesThroughThePOSIXChain() throws {
        #expect(ClipboardCaptureFailure.classify(ClipboardArchiveAppendError(errnoValue: ENOSPC)) == .diskFull)
        #expect(ClipboardCaptureFailure.classify(ClipboardArchiveAppendError(errnoValue: EACCES)) == .permissionDenied)
        #expect(ClipboardCaptureFailure.classify(ClipboardArchiveAppendError(errnoValue: EROFS)) == .readOnlyVolume)
    }

    /// A failed append is recorded as an operational row carrying the errno
    /// class and nothing else.
    @Test func failedAppendRecordsAnOperationalRow() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let log = ClipboardOperationalLog(directory: root.appendingPathComponent("Logs", isDirectory: true))
        var writer = ClipboardArchiveWriter(archiveRoot: root)
        writer.appendFault = ClipboardArchiveWriter.AppendFault(bytesBeforeFailure: 8, errnoValue: ENOSPC)
        let ingestor = ClipboardIngestor(archiveWriter: writer, operationalLog: log)

        #expect(throws: ClipboardArchiveAppendError.self) {
            _ = try ingestor.ingest(capture("a row that cannot land", at: Date(timeIntervalSince1970: 1_800_000_000)))
        }
        let rows = log.read(limit: 50)
        let appendFailures = rows.filter { $0.code == "archive_append_failed" }
        print("APPEND_OPLOG codes=\(rows.map(\.code)) errno=\(appendFailures.first?.numbers["errno"] ?? -1)")
        #expect(appendFailures.count == 1)
        #expect(appendFailures.first?.numbers["errno"] == Double(ENOSPC))
        #expect(rows.contains { $0.code == "capture_failed" })
    }
}
