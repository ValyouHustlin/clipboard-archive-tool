import Foundation
import Testing
@testable import ClipboardArchiveCore

/// Where a row lands when the clock moves. The writer files events by UTC
/// day and stamps ids from a UTC formatter, so day boundaries and daylight
/// saving are properties of the ARCHIVE LAYOUT, not of the machine's region:
/// two captures a second apart across a local DST jump stay in the same UTC
/// day file. (The health report and the manifest deliberately use
/// `Calendar.current` instead, because "today" on a dashboard means the
/// person's today; the two are different questions and stay separate.)
@Suite("Clock and day rollover")
struct ArchiveClockRolloverTests {
    private func temporaryRoot() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("clipboard-clock-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func capture(_ content: String, at capturedAt: Date) -> ClipboardCapture {
        ClipboardCapture(
            capturedAt: capturedAt,
            content: content,
            sourceApp: ClipboardSourceApp(name: "Clock Test", bundleIdentifier: "test.clock"),
            pasteboardTypes: ["public.utf8-plain-text"]
        )
    }

    private func dayFiles(in root: URL) throws -> [String] {
        try ClipboardArchiveReader(archiveRoot: root).eventFiles()
            .map(\.lastPathComponent)
            .sorted()
    }

    private func date(_ iso: String) throws -> Date {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return try #require(formatter.date(from: iso))
    }

    /// One second either side of a UTC midnight: two day files, one row each.
    @Test func rowsSplitAcrossAUTCMidnight() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let writer = ClipboardArchiveWriter(archiveRoot: root)

        let before = try writer.archiveAllowedCapture(
            capture("last clip of the day", at: try date("2026-03-07T23:59:59Z"))
        )
        let after = try writer.archiveAllowedCapture(
            capture("first clip of the day", at: try date("2026-03-08T00:00:01Z"))
        )
        let files = try dayFiles(in: root)
        print("CLOCK_UTC_MIDNIGHT files=\(files) before_id=\(before.id) after_id=\(after.id)")
        #expect(files == ["2026-03-07_clipboard-events.ndjson", "2026-03-08_clipboard-events.ndjson"])
        #expect(before.id.contains("20260307T235959Z"))
        #expect(after.id.contains("20260308T000001Z"))
    }

    /// America/New_York springs forward at 2026-03-08 07:00 UTC; the two
    /// captures around it are the same UTC day, so they share one file and
    /// their ids stay monotonic — a local clock jump moves no rows.
    @Test func daylightSavingJumpDoesNotSplitTheUTCDay() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let writer = ClipboardArchiveWriter(archiveRoot: root)
        #expect(TimeZone(identifier: "America/New_York")?.isDaylightSavingTime(
            for: try date("2026-03-08T08:00:00Z")
        ) == true)
        #expect(TimeZone(identifier: "America/New_York")?.isDaylightSavingTime(
            for: try date("2026-03-08T06:00:00Z")
        ) == false)
        // Phoenix observes no DST at all: the same two instants, no jump.
        #expect(TimeZone(identifier: "America/Phoenix")?.isDaylightSavingTime(
            for: try date("2026-03-08T08:00:00Z")
        ) == false)

        let before = try writer.archiveAllowedCapture(
            capture("before the spring forward", at: try date("2026-03-08T06:59:59Z"))
        )
        let after = try writer.archiveAllowedCapture(
            capture("after the spring forward", at: try date("2026-03-08T07:00:01Z"))
        )
        let files = try dayFiles(in: root)
        print("CLOCK_DST files=\(files) before_id=\(before.id) after_id=\(after.id)")
        #expect(files == ["2026-03-08_clipboard-events.ndjson"])
        #expect(before.id < after.id)
    }

    /// The autumn fall-back repeats a local hour; in UTC nothing repeats, so
    /// two captures an hour apart still land in one file with distinct ids.
    @Test func repeatedLocalHourStillProducesDistinctRows() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let writer = ClipboardArchiveWriter(archiveRoot: root)

        let first = try writer.archiveAllowedCapture(
            capture("first pass through 1:30", at: try date("2026-11-01T05:30:00Z"))
        )
        let second = try writer.archiveAllowedCapture(
            capture("second pass through 1:30", at: try date("2026-11-01T06:30:00Z"))
        )
        let files = try dayFiles(in: root)
        print("CLOCK_FALLBACK files=\(files) ids=\(first.id),\(second.id)")
        #expect(files == ["2026-11-01_clipboard-events.ndjson"])
        #expect(first.id != second.id)
    }

    /// Two captures with the SAME instant and the SAME content: same day
    /// file, same content hash, different ids — one clip can never overwrite
    /// or shadow the other.
    @Test func identicalInstantAndContentStillProduceUniqueIDs() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let writer = ClipboardArchiveWriter(archiveRoot: root)
        let instant = try date("2026-06-15T12:00:00Z")

        let first = try writer.archiveAllowedCapture(capture("identical body", at: instant))
        let second = try writer.archiveAllowedCapture(capture("identical body", at: instant))
        let stored = try ClipboardArchiveReader(archiveRoot: root)
            .recentItems(since: .distantPast, limit: 10)
        print("CLOCK_UNIQUE_IDS ids=\(first.id),\(second.id) hash_equal=\(first.contentHash == second.contentHash) stored=\(stored.count)")
        #expect(first.id != second.id)
        #expect(first.contentHash == second.contentHash)
        #expect(stored.count == 2)
    }

    /// A clock that jumps FORWARD must not hide clips: a row stamped a day
    /// ahead is still found by a recent-items read taken now.
    @Test func forwardClockJumpDoesNotHideARow() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let writer = ClipboardArchiveWriter(archiveRoot: root)
        let now = Date()

        _ = try writer.archiveAllowedCapture(capture("clip from the present", at: now))
        _ = try writer.archiveAllowedCapture(
            capture("clip from the future", at: now.addingTimeInterval(86_400))
        )
        let reader = ClipboardArchiveReader(archiveRoot: root)
        let recent = try reader.recentItems(since: now.addingTimeInterval(-3_600), limit: 10)
        let previews = recent.map(\.contentPreview).sorted()
        print("CLOCK_FORWARD_JUMP files=\(try dayFiles(in: root)) found=\(previews)")
        #expect(previews == ["clip from the future", "clip from the present"])
    }
}
