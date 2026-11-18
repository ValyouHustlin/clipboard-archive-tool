import Foundation
import Testing
@testable import ClipboardArchiveCore

/// Fixes from the 2026-11 whole-project review that had no test of their own.
@Suite("Review list fixes")
struct ReviewListFixTests {
    private func scratch(_ label: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("clipboard-review-\(label)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func capture(_ content: String, daysAgo: Double) -> ClipboardCapture {
        ClipboardCapture(
            capturedAt: Date().addingTimeInterval(-daysAgo * 86_400),
            content: content,
            sourceApp: ClipboardSourceApp(name: "Notes", bundleIdentifier: "com.apple.Notes"),
            pasteboardTypes: ["public.utf8-plain-text"]
        )
    }

    private func dayFiles(_ root: URL) throws -> [URL] {
        try ClipboardArchiveReader(archiveRoot: root).eventFiles()
    }

    // MARK: Retention

    /// In a "keep latest N" archive the limit is enforced after every
    /// capture. A day file in which everything is already pruned must not be
    /// read again each time. Making it unreadable proves it is skipped: a
    /// second read would throw.
    @Test func aDayFileWithNothingLiveIsNotReadAgainUntilItChanges() throws {
        let root = try scratch("retention")
        let indexFolder = try scratch("retention-index")
        defer {
            for file in (try? dayFiles(root)) ?? [] {
                try? FileManager.default.setAttributes([.posixPermissions: NSNumber(value: Int16(0o600))], ofItemAtPath: file.path)
            }
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: indexFolder)
        }
        let writer = ClipboardArchiveWriter(archiveRoot: root)
        let pruner = ClipboardArchivePruner(archiveRoot: root, indexURL: indexFolder.appendingPathComponent("index.sqlite"))
        for number in 0..<4 {
            try writer.archiveAllowedCapture(capture("old clip \(number)", daysAgo: 6))
        }
        for number in 0..<3 {
            try writer.archiveAllowedCapture(capture("recent clip \(number)", daysAgo: 0))
        }

        let first = try pruner.enforceRetentionLimit(keepingMostRecent: 3)
        #expect(first.prunedEvents == 4)
        // The pass after a prune is the one that finds the old day file
        // fully pruned and remembers it.
        #expect(try pruner.enforceRetentionLimit(keepingMostRecent: 3).prunedEvents == 0)
        let oldFile = try #require(try dayFiles(root).first)
        try FileManager.default.setAttributes([.posixPermissions: NSNumber(value: Int16(0o000))], ofItemAtPath: oldFile.path)

        // One more capture puts the archive over the limit again.
        try writer.archiveAllowedCapture(capture("newest clip", daysAgo: 0))
        let second = try pruner.enforceRetentionLimit(keepingMostRecent: 3)
        #expect(second.prunedEvents == 1)

        // A change to the old file (a restore bringing a clip back) is seen.
        try FileManager.default.setAttributes([.posixPermissions: NSNumber(value: Int16(0o600))], ofItemAtPath: oldFile.path)
        let restored = try writer.archiveAllowedCapture(capture("restored into the old day", daysAgo: 6))
        let third = try pruner.enforceRetentionLimit(keepingMostRecent: 3)
        #expect(third.prunedEvents == 1)
        let kept = try ClipboardArchiveReader(archiveRoot: root).recentItems(since: .distantPast, limit: 20)
        #expect(kept.count == 3)
        #expect(!kept.contains { $0.id == restored.id })
    }

    // MARK: Single delete

    /// A delete opens the day its clip was captured on first, and falls
    /// back to the original order for an id it cannot read a day from.
    @Test func aDeleteLooksInTheClipsOwnDayFirst() {
        let files = ["2026-11-15", "2026-11-16", "2026-11-17"].map {
            URL(fileURLWithPath: "/tmp/archive/raw/2026/11/\($0)_clipboard-events.ndjson")
        }
        let ordered = ClipboardArchiveRedactor.searchOrder(files, eventID: "clip_20261117T080000Z_aaaaaaaaaaaa_bbbbbbbb")
        #expect(ordered.first == files[2])
        #expect(Set(ordered) == Set(files))
        #expect(ordered.count == files.count)
        #expect(ClipboardArchiveRedactor.searchOrder(files, eventID: "clip_synthetic_7") == files)
        #expect(ClipboardArchiveRedactor.searchOrder(files, eventID: "clip_20250101T000000Z_a_b") == files)
        #expect(ClipboardArchiveRedactor.searchOrder(files, eventID: "nonsense") == files)
    }

    // MARK: Settings

    /// One value this build does not know used to fail the whole decode,
    /// which reset every setting to its default and switched capture off.
    @Test func anUnknownSettingValueKeepsEveryOtherChoice() throws {
        let base = try scratch("settings")
        defer { try? FileManager.default.removeItem(at: base) }
        let url = base.appendingPathComponent("settings.json")
        try Data("""
        {"archiveEnabled":true,"hasCompletedOnboarding":true,"settingsVersion":1,
         "excludedBundleIdentifiers":["com.example.bank"],"pollIntervalSeconds":0.5,
         "historyWindow":90,"retentionMode":"recent-200"}
        """.utf8).write(to: url)

        let loaded = ClipboardSettingsStore(settingsURL: url).loadReporting()
        #expect(loaded.fallback == nil)
        #expect(loaded.settings.archiveEnabled)
        #expect(loaded.settings.hasCompletedOnboarding)
        #expect(loaded.settings.excludedBundleIdentifiers == ["com.example.bank"])
        #expect(loaded.settings.pollIntervalSeconds == 0.5)
        // The unknown retention mode must not turn into one that deletes.
        #expect(loaded.settings.retentionMode == .unlimited)
        #expect(loaded.settings.historyWindow == .sevenDays)
    }

    // MARK: Deletion ledger

    /// A ledger row cut short by a crash has no terminator. The next row
    /// must start on its own line, or both are unreadable and a later merge
    /// restore brings those deleted clips back.
    @Test func aLedgerRowAfterATornRowIsStillRead() throws {
        let root = try scratch("ledger")
        defer { try? FileManager.default.removeItem(at: root) }
        let ledger = ClipboardDeletionLedger(archiveRoot: root)
        try ledger.recordDeletion(eventID: "clip_first")

        let ledgerFiles = FileManager.default.enumerator(at: root.appendingPathComponent("deletion-ledger"), includingPropertiesForKeys: nil)?
            .compactMap { $0 as? URL }
            .filter { (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true } ?? []
        let file = try #require(ledgerFiles.first)
        let handle = try FileHandle(forWritingTo: file)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(#"{"clipboardEventID":"clip_torn","dele"#.utf8))
        try handle.close()

        try ledger.recordDeletion(eventID: "clip_second")
        let deleted = try ClipboardDeletionLedger(archiveRoot: root).deletedIDs()
        #expect(deleted.contains("clip_first"))
        #expect(deleted.contains("clip_second"))
        #expect(try String(contentsOf: file, encoding: .utf8).hasSuffix("\n"))
    }

    // MARK: Credentials the detector missed

    /// Made-up credentials, assembled here so that no token-shaped string
    /// sits in the source for a secret scanner to find.
    private static let madeUpCredentials: [(name: String, text: String)] = [
        ("a fine-grained GitHub token",
         "here is the PAT " + ["github", "pat", "11ABCDEFG0abcdefghijkl", "mnopqrstuvwxyz0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefgh"].joined(separator: "_") + " for the script"),
        ("a temporary AWS key",
         "export AWS_ID " + "ASIA" + "ABCDEFGHIJKLMNOP" + " and go"),
        ("a Slack app token",
         "token is " + ["xapp", "1", "A0123456789", "1234567890123", "abcdef0123456789"].joined(separator: "-")),
        ("a Slack refresh token",
         "use " + ["xoxe", "1", "My0xLWFiY2RlZmdoaWprbG1ub3A"].joined(separator: "-") + " for refresh")
    ]

    @Test func aCredentialInsideOrdinaryTextIsFlagged() {
        for credential in Self.madeUpCredentials {
            #expect(SecretDetector().inspect(credential.text).isSensitive, "missed \(credential.name)")
        }
    }

    @Test func ordinaryTextIsStillAllowed() {
        for text in [
            "The quarterly report is due on Friday; please review the numbers.",
            "https://example.com/docs/getting-started?page=2",
            "git commit 3a907b9 pins the workflow actions",
            "ASIA trip itinerary: Tokyo, Seoul, Taipei"
        ] {
            #expect(!SecretDetector().inspect(text).isSensitive, "blocked ordinary text: \(text)")
        }
    }
}
