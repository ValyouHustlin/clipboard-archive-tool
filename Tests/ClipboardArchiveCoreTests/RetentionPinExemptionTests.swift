import Foundation
import Testing
@testable import ClipboardArchiveCore

/// Slice 4 pin exemption for retention pruning (contract 5): pinned content
/// sits OUTSIDE the retention limit; `includePinned` is the explicit
/// override; last-occurrence pruning sweeps annotation references.
/// Append-only extension of the retention suite — new file, synthetic
/// fixtures under temp roots only (contract 10).
@Suite("Retention Pin Exemption")
struct RetentionPinExemptionTests {
    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("clipboard-pin-retention-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func makeEvent(
        id: String,
        capturedAt: Date,
        content: String,
        contentHash: String? = nil
    ) -> StoredClipboardEvent {
        StoredClipboardEvent(
            id: id,
            capturedAt: capturedAt,
            contentType: .text,
            contentHash: contentHash ?? "sha256:synthetic-\(id)",
            contentPreview: String(content.prefix(240)),
            contentInline: content,
            rawContentPath: nil,
            sourceApp: ClipboardSourceApp(name: "Synthetic Test", bundleIdentifier: "test.synthetic"),
            pasteboardTypes: ["public.utf8-plain-text"],
            byteCount: content.utf8.count,
            characterCount: content.count,
            lineCount: 1,
            privacyLabel: .privateLocal,
            allowedUse: [.localSearch, .localAnalysis],
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

    private func modificationDate(of url: URL) throws -> Date {
        let values = try url.resourceValues(forKeys: [.contentModificationDateKey])
        return values.contentModificationDate ?? Date.distantPast
    }

    // MARK: - Incremental enforcement keeps pinned OUTSIDE the limit

    @Test
    func testEnforceRetentionLimitKeepsPinnedOutsideTheLimit() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let indexURL = root.appendingPathComponent("index.sqlite")
        let base = ISO8601DateFormatter().date(from: "2026-07-20T08:00:00Z")!

        var seeded: [StoredClipboardEvent] = []
        for slot in 0..<14 {
            let event = makeEvent(
                id: String(format: "evt-pin-%02d", slot),
                capturedAt: base.addingTimeInterval(Double(slot) * 60),
                content: "synthetic pin retention fixture \(slot)"
            )
            seeded.append(event)
            try appendEventLine(event, archiveRoot: root)
        }

        // Pin the two OLDEST; tag the oldest UNPINNED event's hash so the
        // annotation sweep is exercised in the same pass.
        let store = ClipboardAnnotationsStore(archiveRoot: root)
        try store.setPinned(true, forContentHash: seeded[0].contentHash)
        try store.setPinned(true, forContentHash: seeded[1].contentHash)
        try store.setTags(["doomed"], forContentHash: seeded[2].contentHash)

        let result = try ClipboardArchivePruner(archiveRoot: root, indexURL: indexURL)
            .enforceRetentionLimit(keepingMostRecent: 10)

        // 14 live, 2 pinned exempt → 12 counted; keep newest 10 unpinned →
        // prune the 2 oldest UNPINNED (slots 2 and 3).
        #expect(result.liveEvents == 14)
        #expect(result.exemptPinnedEvents == 2)
        #expect(result.prunedEvents == 2)
        #expect(result.keptEvents == 12)
        #expect(result.keptCountedEvents == 10)

        let live = try ClipboardArchiveReader(archiveRoot: root)
            .recentItems(since: .distantPast, limit: 100)
        let liveIDs = Set(live.map(\.id))
        #expect(liveIDs.contains("evt-pin-00"))
        #expect(liveIDs.contains("evt-pin-01"))
        #expect(!liveIDs.contains("evt-pin-02"))
        #expect(!liveIDs.contains("evt-pin-03"))
        #expect(liveIDs.count == 12)

        // Pins survive in the store; the fully pruned hash lost its record.
        #expect(store.pinnedContentHashes()
            == [seeded[0].contentHash, seeded[1].contentHash])
        #expect(store.annotation(for: seeded[2].contentHash) == nil)
    }

    @Test
    func testAllPinnedOverLimitIsZeroWrites() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let indexURL = root.appendingPathComponent("index.sqlite")
        let base = ISO8601DateFormatter().date(from: "2026-07-21T08:00:00Z")!

        let store = ClipboardAnnotationsStore(archiveRoot: root)
        for slot in 0..<5 {
            let event = makeEvent(
                id: "evt-allpin-\(slot)",
                capturedAt: base.addingTimeInterval(Double(slot) * 60),
                content: "synthetic all-pinned fixture \(slot)"
            )
            try appendEventLine(event, archiveRoot: root)
            try store.setPinned(true, forContentHash: event.contentHash)
        }

        let dayFile = dayFileURL(for: base, archiveRoot: root)
        let bytesBefore = try Data(contentsOf: dayFile)
        let modifiedBefore = try modificationDate(of: dayFile)

        // 5 live, all pinned, limit 3: pinned-only over the limit is NOT
        // overflow — zero writes, zero ledger records.
        let result = try ClipboardArchivePruner(archiveRoot: root, indexURL: indexURL)
            .enforceRetentionLimit(keepingMostRecent: 3)

        #expect(result.liveEvents == 5)
        #expect(result.exemptPinnedEvents == 5)
        #expect(result.prunedEvents == 0)
        #expect(result.changedFiles == 0)
        #expect(result.keptCountedEvents == 0)
        #expect(try Data(contentsOf: dayFile) == bytesBefore)
        #expect(try modificationDate(of: dayFile) == modifiedBefore)
        #expect(try ClipboardDeletionLedger(archiveRoot: root).deletedIDs().isEmpty)
    }

    // MARK: - Cutoff prune exemption + dry-run parity

    @Test
    func testCutoffPruneExemptsPinnedWithDryRunParity() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let indexURL = root.appendingPathComponent("index.sqlite")
        let formatter = ISO8601DateFormatter()
        let base = formatter.date(from: "2026-07-01T08:00:00Z")!
        let cutoff = formatter.date(from: "2026-07-01T08:03:00Z")!

        var seeded: [StoredClipboardEvent] = []
        for slot in 0..<5 {
            let event = makeEvent(
                id: "evt-cutoff-\(slot)",
                capturedAt: base.addingTimeInterval(Double(slot) * 60),
                content: "synthetic cutoff fixture \(slot)"
            )
            seeded.append(event)
            try appendEventLine(event, archiveRoot: root)
        }
        // Slots 0-2 fall before the cutoff; pin slot 1.
        let store = ClipboardAnnotationsStore(archiveRoot: root)
        try store.setPinned(true, forContentHash: seeded[1].contentHash)

        let pruner = ClipboardArchivePruner(archiveRoot: root, indexURL: indexURL)
        let dayFile = dayFileURL(for: base, archiveRoot: root)
        let bytesBefore = try Data(contentsOf: dayFile)

        // Dry run: truthful numbers, zero changes.
        let dryRun = try pruner.pruneContent(before: cutoff, dryRun: true)
        #expect(dryRun.prunedEvents == 2)
        #expect(dryRun.exemptedPinnedEvents == 1)
        #expect(dryRun.dryRun)
        #expect(try Data(contentsOf: dayFile) == bytesBefore)
        #expect(store.pinnedContentHashes() == [seeded[1].contentHash])

        // Real run: same numbers (dry-run parity), pinned event survives.
        let real = try pruner.pruneContent(before: cutoff)
        #expect(real.prunedEvents == dryRun.prunedEvents)
        #expect(real.exemptedPinnedEvents == dryRun.exemptedPinnedEvents)

        let live = try ClipboardArchiveReader(archiveRoot: root)
            .recentItems(since: .distantPast, limit: 100)
        #expect(Set(live.map(\.id)) == ["evt-cutoff-1", "evt-cutoff-3", "evt-cutoff-4"])
        #expect(store.pinnedContentHashes() == [seeded[1].contentHash])
    }

    // MARK: - Explicit include-pinned override

    @Test
    func testIncludePinnedPrunesPinnedAndSweepsAnnotationReferences() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let indexURL = root.appendingPathComponent("index.sqlite")
        let formatter = ISO8601DateFormatter()
        let base = formatter.date(from: "2026-07-02T08:00:00Z")!
        let cutoff = formatter.date(from: "2026-07-02T08:02:00Z")!

        let pinnedOld = makeEvent(
            id: "evt-incl-0",
            capturedAt: base,
            content: "synthetic include-pinned fixture old"
        )
        let keptNew = makeEvent(
            id: "evt-incl-1",
            capturedAt: base.addingTimeInterval(300),
            content: "synthetic include-pinned fixture new"
        )
        try appendEventLine(pinnedOld, archiveRoot: root)
        try appendEventLine(keptNew, archiveRoot: root)

        let store = ClipboardAnnotationsStore(archiveRoot: root)
        try store.setPinned(true, forContentHash: pinnedOld.contentHash)
        let collection = try store.createCollection(named: "Sweep Me")
        try store.setMembership(
            contentHash: pinnedOld.contentHash,
            inCollection: collection.id,
            isMember: true
        )

        let result = try ClipboardArchivePruner(archiveRoot: root, indexURL: indexURL)
            .pruneContent(before: cutoff, includePinned: true)

        #expect(result.prunedEvents == 1)
        #expect(result.exemptedPinnedEvents == 0)

        // The pinned event is gone AND its annotation references were swept
        // (record dropped, collection membership stripped).
        let live = try ClipboardArchiveReader(archiveRoot: root)
            .recentItems(since: .distantPast, limit: 100)
        #expect(live.map(\.id) == ["evt-incl-1"])
        #expect(store.annotation(for: pinnedOld.contentHash) == nil)
        #expect(store.collections().first?.contentHashes == [])
    }

    // MARK: - Annotation sweep spares surviving occurrences

    @Test
    func testAnnotationSurvivesWhileAnyOccurrenceRemainsLive() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let indexURL = root.appendingPathComponent("index.sqlite")
        let formatter = ISO8601DateFormatter()
        let base = formatter.date(from: "2026-07-03T08:00:00Z")!
        let sharedHash = "sha256:shared-annotated-content"

        let older = makeEvent(
            id: "evt-shared-0",
            capturedAt: base,
            content: "synthetic shared content",
            contentHash: sharedHash
        )
        let newer = makeEvent(
            id: "evt-shared-1",
            capturedAt: base.addingTimeInterval(600),
            content: "synthetic shared content",
            contentHash: sharedHash
        )
        try appendEventLine(older, archiveRoot: root)
        try appendEventLine(newer, archiveRoot: root)

        let store = ClipboardAnnotationsStore(archiveRoot: root)
        try store.setTags(["sticky"], forContentHash: sharedHash)

        let pruner = ClipboardArchivePruner(archiveRoot: root, indexURL: indexURL)

        // Prune only the older occurrence: the annotation must survive
        // because a live occurrence remains.
        _ = try pruner.pruneContent(before: base.addingTimeInterval(60))
        #expect(store.annotation(for: sharedHash)?.tags == ["sticky"])

        // Prune the last occurrence: the annotation reference is removed.
        _ = try pruner.pruneContent(before: base.addingTimeInterval(3_600))
        #expect(store.annotation(for: sharedHash) == nil)
    }
}
