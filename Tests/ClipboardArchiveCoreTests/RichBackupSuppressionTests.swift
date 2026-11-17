import Foundation
import Testing
@testable import ClipboardArchiveCore

/// Regression coverage for the review-caught critical: merge-restore must
/// suppress EVERY body a locally-deleted event references — the rich
/// payload (image/RTF/file-list spill) as well as the plain-text fallback.
@Suite("Rich Backup Suppression", .serialized)
struct RichBackupSuppressionTests {
    @Test func locallyDeletedRichBodyIsNeverResurrected() throws {
        let sourceRoot = try BackupTestSupport.temporaryDirectory("rich-deleted-src")
        let writer = ClipboardArchiveWriter(archiveRoot: sourceRoot)
        let pngBytes = Data([
            0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A,
            0x73, 0x79, 0x6E, 0x74, 0x68, 0x65, 0x74, 0x69, 0x63
        ])
        let richEvent = try writer.archiveAllowedCapture(ClipboardCapture(
            capturedAt: Date().addingTimeInterval(-3600),
            content: "",
            sourceApp: ClipboardSourceApp(name: "Preview", bundleIdentifier: "com.apple.Preview"),
            pasteboardTypes: ["public.png"],
            rich: .image(data: pngBytes, uti: "public.png", pixelWidth: 1, pixelHeight: 1)
        ))
        let richBodyPath = try #require(richEvent.richContent?.bodyPath)

        let backupFile = try BackupTestSupport.temporaryDirectory("rich-deleted-out")
            .appendingPathComponent("backup.clipbak")
        _ = try BackupTestSupport.export(sourceRoot, to: backupFile)

        // Target = same archive, then the rich event is locally redacted:
        // its body file is gone and its id is in the local ledger.
        let target = try BackupTestSupport.temporaryDirectory("rich-deleted-dst")
        try FileManager.default.removeItem(at: target)
        try BackupTestSupport.copyTree(sourceRoot, to: target)
        let targetIndex = try BackupTestSupport.temporaryDirectory("rich-deleted-idx")
            .appendingPathComponent("index.sqlite")
        _ = try ClipboardArchiveRedactor(archiveRoot: target, indexURL: targetIndex)
            .redact(eventID: richEvent.id)
        let bodyURL = try ClipboardArchivePath.containedURL(
            relativePath: richBodyPath,
            archiveRoot: target
        )
        #expect(!FileManager.default.fileExists(atPath: bodyURL.path))

        let importer = ClipboardBackupImporter(
            archiveRoot: target,
            indexURL: targetIndex,
            settingsURL: try BackupTestSupport.temporaryDirectory("rich-deleted-cfg")
                .appendingPathComponent("settings.json")
        )
        let outcome = try importer.run(
            backupFileURL: backupFile,
            passphrase: BackupTestSupport.passphrase,
            options: ClipboardBackupImportOptions(merge: true),
            dryRun: false
        )

        #expect(outcome.plan.skippedDeletedHere == 1)
        #expect(outcome.plan.bodiesToAdd == 0)
        // The deleted image bytes must never come back — not as a
        // referenced body and not as an orphaned file.
        #expect(!FileManager.default.fileExists(atPath: bodyURL.path))
        let reader = ClipboardArchiveReader(archiveRoot: target)
        #expect(try reader.event(withID: richEvent.id) == nil)
    }
}
