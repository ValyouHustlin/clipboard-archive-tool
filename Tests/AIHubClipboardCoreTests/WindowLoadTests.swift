import Foundation
import Testing
@testable import ClipboardArchiveCore

/// The two pieces that let the history window load off the main thread:
/// the generation bookkeeping that decides which completion is allowed to
/// put rows on screen, and the day-file line reader the load runs on.
/// Synthetic data only, temporary roots only.
@Suite("Window load")
struct WindowLoadTests {
    // MARK: - Generations

    @Test func newestLoadApplies() {
        var generations = ClipboardLoadGenerations()
        let first = generations.begin()
        #expect(generations.isLoading)
        let applied = generations.accept(first)
        #expect(applied)
        #expect(!generations.isLoading)
    }

    /// Two loads in flight, the older finishing last: the older result is
    /// refused, which is the whole point — it would otherwise put stale
    /// rows over the newer ones.
    @Test func overtakenLoadIsDropped() {
        var generations = ClipboardLoadGenerations()
        let first = generations.begin()
        let second = generations.begin()
        let newestApplied = generations.accept(second)
        let overtakenApplied = generations.accept(first)
        #expect(newestApplied)
        #expect(!overtakenApplied)
    }

    /// A completion arriving out of order never lowers the high-water mark,
    /// so a late straggler cannot make a finished load look outstanding.
    @Test func lateCompletionDoesNotReopenAFinishedLoad() {
        var generations = ClipboardLoadGenerations()
        let first = generations.begin()
        let second = generations.begin()
        _ = generations.accept(second)
        #expect(!generations.isLoading)
        _ = generations.accept(first)
        #expect(!generations.isLoading)
        #expect(generations.completed == 2)
    }

    /// What the delayed "Loading…" hint checks: true while its own load is
    /// unfinished, false once that load — or a later one — has completed.
    @Test func hintOnlyShowsWhileItsOwnLoadIsOutstanding() {
        var generations = ClipboardLoadGenerations()
        let first = generations.begin()
        #expect(generations.isOutstanding(first))
        _ = generations.accept(first)
        #expect(!generations.isOutstanding(first))
        let second = generations.begin()
        #expect(generations.isOutstanding(second))
        _ = generations.accept(second)
        #expect(!generations.isOutstanding(second))
    }

    // MARK: - Reader equivalence

    private func temporaryRoot() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("clipboard-window-load-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func seed(root: URL, days: Int, perDay: Int) throws {
        let writer = ClipboardArchiveWriter(archiveRoot: root)
        let base = Date(timeIntervalSince1970: 1_800_000_000)
        for day in 0..<days {
            for item in 0..<perDay {
                let capturedAt = base
                    .addingTimeInterval(TimeInterval(-day) * 86_400)
                    .addingTimeInterval(TimeInterval(item))
                _ = try writer.archiveAllowedCapture(
                    ClipboardCapture(
                        capturedAt: capturedAt,
                        content: "synthetic window fixture day \(day) item \(item)",
                        sourceApp: ClipboardSourceApp(name: "Window Test", bundleIdentifier: "test.window"),
                        pasteboardTypes: ["public.utf8-plain-text"]
                    )
                )
            }
        }
    }

    /// The implementation this replaced: whole file into a `String`, split
    /// on newlines, each line back into UTF-8 bytes. The new reader must
    /// agree with it row for row, in order, at every limit.
    private func referenceRecentItems(
        root: URL,
        since: Date,
        limit: Int
    ) throws -> [StoredClipboardEvent] {
        let reader = ClipboardArchiveReader(archiveRoot: root)
        let suppression = try ClipboardSuppression(archiveRoot: root).snapshot()
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        var items: [StoredClipboardEvent] = []
        for fileURL in try reader.eventFiles().reversed() {
            let lines = try String(contentsOf: fileURL, encoding: .utf8)
                .split(separator: "\n", omittingEmptySubsequences: true)
            for line in lines.reversed() {
                guard let data = String(line).data(using: .utf8),
                      let event = try? decoder.decode(StoredClipboardEvent.self, from: data),
                      event.capturedAt >= since,
                      !suppression.isSuppressed(event) else {
                    continue
                }
                items.append(event)
                if items.count >= limit {
                    return items
                }
            }
        }
        return items
    }

    @Test func readerMatchesTheImplementationItReplacedAtEveryLimit() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try seed(root: root, days: 4, perDay: 25)
        let reader = ClipboardArchiveReader(archiveRoot: root)

        for limit in [1, 10, 37, 100, 500] {
            let produced = try reader.recentItems(since: .distantPast, limit: limit)
            let expected = try referenceRecentItems(root: root, since: .distantPast, limit: limit)
            #expect(produced.map(\.id) == expected.map(\.id))
            #expect(produced.count == min(limit, 100))
        }
        print("WINDOW_READER_EQUIVALENCE limits=1,10,37,100,500 events=100")
    }

    /// The `since` cutoff and the deletion ledger must keep filtering
    /// exactly as before; a day boundary is where an off-by-one would show.
    @Test func readerMatchesTheOldImplementationOnADateCutoff() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try seed(root: root, days: 4, perDay: 25)
        let reader = ClipboardArchiveReader(archiveRoot: root)
        let cutoff = Date(timeIntervalSince1970: 1_800_000_000).addingTimeInterval(-86_400)

        let produced = try reader.recentItems(since: cutoff, limit: 500)
        let expected = try referenceRecentItems(root: root, since: cutoff, limit: 500)
        #expect(produced.map(\.id) == expected.map(\.id))
        #expect(produced.count == 50)
    }

    /// A day file whose tail was torn by a killed write still costs exactly
    /// the torn row: everything before it decodes, in order.
    @Test func tornTailIsStillTolerated() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try seed(root: root, days: 1, perDay: 6)
        let reader = ClipboardArchiveReader(archiveRoot: root)
        let fileURL = try #require(try reader.eventFiles().last)

        var bytes = try Data(contentsOf: fileURL)
        bytes.append(Data(#"{"capturedAt":"2027-01-01T00:00:00Z","contentInl"#.utf8))
        try bytes.write(to: fileURL)

        let produced = try reader.recentItems(since: .distantPast, limit: 100)
        let expected = try referenceRecentItems(root: root, since: .distantPast, limit: 100)
        #expect(produced.map(\.id) == expected.map(\.id))
        #expect(produced.count == 6)
        print("WINDOW_READER_TORN_TAIL rows=\(produced.count)")
    }

    /// A file with no trailing newline at all (the terminator itself was
    /// lost) must not drop its last row.
    @Test func missingTrailingNewlineKeepsTheLastRow() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try seed(root: root, days: 1, perDay: 3)
        let reader = ClipboardArchiveReader(archiveRoot: root)
        let fileURL = try #require(try reader.eventFiles().last)

        var bytes = try Data(contentsOf: fileURL)
        #expect(bytes.last == 0x0A)
        bytes.removeLast()
        try bytes.write(to: fileURL)

        let produced = try reader.recentItems(since: .distantPast, limit: 100)
        #expect(produced.count == 3)
    }

    /// `event(withID:)` reads the same day file through the same line
    /// reader, so it has to keep finding a row in the middle of a file.
    @Test func eventByIDStillResolvesThroughTheNewLineReader() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try seed(root: root, days: 2, perDay: 10)
        let reader = ClipboardArchiveReader(archiveRoot: root)
        let all = try reader.recentItems(since: .distantPast, limit: 100)
        let middle = try #require(all.dropFirst(7).first)

        let fetched = try reader.event(withID: middle.id)
        #expect(fetched?.id == middle.id)
        #expect(fetched?.contentInline == middle.contentInline)
    }
}
