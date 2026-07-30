import Foundation
import Testing
@testable import ClipboardArchiveCore

/// Slice 8 merge-import semantics: one test per row of the merge table,
/// plus the journaled-commit fault matrix and stale-staging recovery.
/// Synthetic fixtures under isolated temp roots only (contract 10).
@Suite("Clipboard Backup Merge", .serialized)
struct ClipboardBackupMergeTests {
    private struct Fixture {
        var sourceRoot: URL
        var sourceIndex: URL
        var backupFile: URL
        var events: [StoredClipboardEvent]
        var redactedID: String
    }

    /// Source archive A with the full mixed shape, exported once.
    private func makeSourceFixture(_ label: String) throws -> Fixture {
        let sourceRoot = try BackupTestSupport.temporaryDirectory("merge-\(label)-src")
        let sourceIndex = try BackupTestSupport.temporaryDirectory("merge-\(label)-src-idx")
            .appendingPathComponent("index.sqlite")
        let seeded = try BackupTestSupport.seedMixedArchive(sourceRoot, indexURL: sourceIndex)
        let backupFile = try BackupTestSupport.temporaryDirectory("merge-\(label)-out")
            .appendingPathComponent("backup.clipbak")
        _ = try BackupTestSupport.export(sourceRoot, to: backupFile)
        return Fixture(
            sourceRoot: sourceRoot,
            sourceIndex: sourceIndex,
            backupFile: backupFile,
            events: seeded.events,
            redactedID: seeded.redactedID
        )
    }

    private func makeImporter(_ root: URL, label: String) throws -> ClipboardBackupImporter {
        ClipboardBackupImporter(
            archiveRoot: root,
            indexURL: try BackupTestSupport.temporaryDirectory("merge-\(label)-idx")
                .appendingPathComponent("index.sqlite"),
            settingsURL: try BackupTestSupport.temporaryDirectory("merge-\(label)-cfg")
                .appendingPathComponent("settings.json")
        )
    }

    // MARK: - Merge table rows

    @Test func newIDsImportIntoUTCDayFiles() throws {
        let fixture = try makeSourceFixture("new")
        let target = try BackupTestSupport.temporaryDirectory("merge-new-dst")
        let local = try BackupTestSupport.seedEvent(target, content: "pre-existing local clip")

        let importer = try makeImporter(target, label: "new")
        let outcome = try importer.run(
            backupFileURL: fixture.backupFile,
            passphrase: BackupTestSupport.passphrase,
            options: ClipboardBackupImportOptions(merge: true),
            dryRun: false
        )
        #expect(outcome.plan.newEvents == 3)
        #expect(outcome.plan.newTombstones == 1)
        #expect(outcome.plan.skippedExistingEvents == 0)
        #expect(outcome.plan.ledgerRecordsToAdd == 1)
        #expect(outcome.plan.bodiesToAdd == 1)

        let reader = ClipboardArchiveReader(archiveRoot: target)
        let recent = try reader.recentItems(since: .distantPast, limit: 100)
        #expect(recent.count == 4) // 3 imported live + 1 local
        #expect(recent.contains { $0.id == local.id })
        for event in fixture.events where event.id != fixture.redactedID {
            let fetched = try reader.event(withID: event.id)
            #expect(fetched?.id == event.id)
            if let fetched {
                #expect(try reader.content(for: fetched) == (try reader.content(for: event)))
            }
        }
    }

    @Test func existingIDsSkipWithoutDuplicateLines() throws {
        let fixture = try makeSourceFixture("existing")
        let target = try BackupTestSupport.temporaryDirectory("merge-existing-dst")
        try FileManager.default.removeItem(at: target)
        try BackupTestSupport.copyTree(fixture.sourceRoot, to: target)
        let before = try BackupTestSupport.treeSignature(target)

        let importer = try makeImporter(target, label: "existing")
        let outcome = try importer.run(
            backupFileURL: fixture.backupFile,
            passphrase: BackupTestSupport.passphrase,
            options: ClipboardBackupImportOptions(merge: true),
            dryRun: false
        )
        #expect(outcome.plan.newEvents == 0)
        #expect(outcome.plan.newTombstones == 0)
        #expect(outcome.plan.skippedExistingEvents == 3)
        // The redacted id sits in the LOCAL ledger too, so it reports as
        // deleted-here, not merely existing.
        #expect(outcome.plan.skippedDeletedHere == 1)
        #expect(outcome.plan.ledgerRecordsToAdd == 0)
        #expect(outcome.plan.blockedLinesToAppend == 0)
        #expect(outcome.plan.blockedLinesSkippedIdentical == 1)
        #expect(outcome.plan.bodiesToAdd == 0)
        #expect(outcome.plan.bodiesSkippedIdentical == 1)
        #expect(try BackupTestSupport.treeSignature(target) == before)
    }

    @Test func locallyDeletedContentIsNeverResurrected() throws {
        // Target = copy of source, then locally redact one LIVE event that
        // the backup still carries in full (content + body).
        let fixture = try makeSourceFixture("deleted")
        let target = try BackupTestSupport.temporaryDirectory("merge-deleted-dst")
        try FileManager.default.removeItem(at: target)
        try BackupTestSupport.copyTree(fixture.sourceRoot, to: target)
        let bodyEvent = try #require(fixture.events.first { $0.rawContentPath != nil })
        let targetIndex = try BackupTestSupport.temporaryDirectory("merge-deleted-target-idx")
            .appendingPathComponent("index.sqlite")
        _ = try ClipboardArchiveRedactor(archiveRoot: target, indexURL: targetIndex)
            .redact(eventID: bodyEvent.id)
        let bodyURL = try ClipboardArchivePath.containedURL(
            relativePath: try #require(bodyEvent.rawContentPath),
            archiveRoot: target
        )
        #expect(!FileManager.default.fileExists(atPath: bodyURL.path))

        let importer = try makeImporter(target, label: "deleted")
        let outcome = try importer.run(
            backupFileURL: fixture.backupFile,
            passphrase: BackupTestSupport.passphrase,
            options: ClipboardBackupImportOptions(merge: true),
            dryRun: false
        )
        #expect(outcome.plan.skippedDeletedHere == 2) // originally redacted + locally redacted
        #expect(outcome.plan.bodiesSkippedDeletedHere == 1)
        #expect(outcome.plan.bodiesToAdd == 0)
        // Content stays gone on disk: no body file, event unreadable.
        #expect(!FileManager.default.fileExists(atPath: bodyURL.path))
        let reader = ClipboardArchiveReader(archiveRoot: target)
        #expect(try reader.event(withID: bodyEvent.id) == nil)
    }

    @Test func ledgerUnionSuppressesLocallyLiveEvents() throws {
        // Source and target share event ids; the SOURCE then deletes one,
        // and its backup carries that ledger record. Importing must union
        // the ledger and suppress the still-live local copy everywhere.
        let sourceRoot = try BackupTestSupport.temporaryDirectory("merge-union-src")
        let e1 = try BackupTestSupport.seedEvent(sourceRoot, content: "union fixture one", minutesAgo: 60)
        let e2 = try BackupTestSupport.seedEvent(sourceRoot, content: "union fixture two", minutesAgo: 50)
        let target = try BackupTestSupport.temporaryDirectory("merge-union-dst")
        try FileManager.default.removeItem(at: target)
        try BackupTestSupport.copyTree(sourceRoot, to: target)

        let sourceIndex = try BackupTestSupport.temporaryDirectory("merge-union-src-idx")
            .appendingPathComponent("index.sqlite")
        _ = try ClipboardArchiveRedactor(archiveRoot: sourceRoot, indexURL: sourceIndex)
            .redact(eventID: e2.id)
        let backupFile = try BackupTestSupport.temporaryDirectory("merge-union-out")
            .appendingPathComponent("union.clipbak")
        _ = try BackupTestSupport.export(sourceRoot, to: backupFile)

        let importer = try makeImporter(target, label: "union")
        let outcome = try importer.run(
            backupFileURL: backupFile,
            passphrase: BackupTestSupport.passphrase,
            options: ClipboardBackupImportOptions(merge: true),
            dryRun: false
        )
        #expect(outcome.plan.ledgerRecordsToAdd == 1)
        #expect(outcome.plan.locallyLiveNewlySuppressed == 1)
        #expect(outcome.indexRebuildFailed == false)

        // Suppressed via the ONE gate...
        let snapshot = try ClipboardSuppression(archiveRoot: target).snapshot()
        #expect(snapshot.deletedIDs.contains(e2.id))
        let reader = ClipboardArchiveReader(archiveRoot: target)
        #expect(try reader.event(withID: e2.id) == nil)
        let recent = try reader.recentItems(since: .distantPast, limit: 10)
        #expect(!recent.contains { $0.id == e2.id })
        #expect(recent.contains { $0.id == e1.id })
        // ...and absent from the rebuilt index.
        let index = ClipboardDerivedIndex(archiveRoot: target, indexURL: importer.indexURL)
        #expect(try index.occurrenceIDs(contentHash: e2.contentHash).isEmpty)
        #expect(try index.occurrenceIDs(contentHash: e1.contentHash) == [e1.id])
    }

    @Test func backupTombstoneImportsWithoutContent() throws {
        let fixture = try makeSourceFixture("tomb")
        let target = try BackupTestSupport.temporaryDirectory("merge-tomb-dst")
        _ = try BackupTestSupport.seedEvent(target, content: "unrelated local clip")

        let importer = try makeImporter(target, label: "tomb")
        let outcome = try importer.run(
            backupFileURL: fixture.backupFile,
            passphrase: BackupTestSupport.passphrase,
            options: ClipboardBackupImportOptions(merge: true),
            dryRun: false
        )
        #expect(outcome.plan.newTombstones == 1)
        // The tombstone line landed but stays invisible on every surface.
        let reader = ClipboardArchiveReader(archiveRoot: target)
        #expect(try reader.event(withID: fixture.redactedID) == nil)
        let dayFiles = try reader.eventFiles()
        let tombstonePresent = try dayFiles.contains { url in
            try String(contentsOf: url).contains(fixture.redactedID)
        }
        #expect(tombstonePresent)
    }

    @Test func blockedLinesAppendIdempotently() throws {
        let fixture = try makeSourceFixture("blocked")
        let target = try BackupTestSupport.temporaryDirectory("merge-blocked-dst")
        _ = try BackupTestSupport.seedEvent(target, content: "blocked-test local clip")

        let importer = try makeImporter(target, label: "blocked")
        let first = try importer.run(
            backupFileURL: fixture.backupFile,
            passphrase: BackupTestSupport.passphrase,
            options: ClipboardBackupImportOptions(merge: true),
            dryRun: false
        )
        #expect(first.plan.blockedLinesToAppend == 1)
        #expect(first.plan.blockedLinesSkippedIdentical == 0)

        let second = try importer.run(
            backupFileURL: fixture.backupFile,
            passphrase: BackupTestSupport.passphrase,
            options: ClipboardBackupImportOptions(merge: true),
            dryRun: false
        )
        #expect(second.plan.blockedLinesToAppend == 0)
        #expect(second.plan.blockedLinesSkippedIdentical == 1)
        #expect(second.plan.newEvents == 0)
    }

    @Test func divergentBodyHashAbortsWholeImportPreWrite() throws {
        let fixture = try makeSourceFixture("diverge")
        let target = try BackupTestSupport.temporaryDirectory("merge-diverge-dst")
        try FileManager.default.removeItem(at: target)
        try BackupTestSupport.copyTree(fixture.sourceRoot, to: target)
        let bodyEvent = try #require(fixture.events.first { $0.rawContentPath != nil })
        let bodyURL = try ClipboardArchivePath.containedURL(
            relativePath: try #require(bodyEvent.rawContentPath),
            archiveRoot: target
        )
        try Data("locally divergent body bytes".utf8).write(to: bodyURL)
        let before = try BackupTestSupport.treeSignature(target)

        let importer = try makeImporter(target, label: "diverge")
        do {
            _ = try importer.run(
                backupFileURL: fixture.backupFile,
                passphrase: BackupTestSupport.passphrase,
                options: ClipboardBackupImportOptions(merge: true),
                dryRun: false
            )
            Issue.record("divergent body import unexpectedly succeeded")
        } catch let error as ClipboardBackupError {
            if case .divergentBodyContent = error {
                // expected
            } else {
                Issue.record("unexpected error: \(error)")
            }
        }
        #expect(try BackupTestSupport.treeSignature(target) == before)
        #expect(BackupTestSupport.stagingDirectories(target).isEmpty)
    }

    @Test func annotationRecordMergeRules() throws {
        let early = Date(timeIntervalSince1970: 1_700_000_000)
        let late = Date(timeIntervalSince1970: 1_800_000_000)
        let local = ClipboardAnnotationRecord(
            pinned: false,
            pinnedAt: nil,
            tags: ["Alpha", "shared"],
            snippet: false,
            snippetTitle: "Local Title",
            sensitivityOverride: "restricted",
            expiresAt: late
        )
        let imported = ClipboardAnnotationRecord(
            pinned: true,
            pinnedAt: late,
            tags: ["beta", "SHARED"],
            snippet: true,
            snippetTitle: "Imported Title",
            sensitivityOverride: nil,
            expiresAt: early
        )
        let merged = ClipboardBackupImporter.mergedAnnotation(local: local, imported: imported)
        #expect(merged.pinned == true)
        #expect(merged.pinnedAt == late)
        #expect(merged.tags == ["Alpha", "shared", "beta"])
        #expect(merged.snippet == true)
        #expect(merged.snippetTitle == "Local Title") // local wins
        #expect(merged.sensitivityOverride == "restricted") // local wins
        #expect(merged.expiresAt == early) // earlier wins (privacy)

        // pinnedAt takes the EARLIER timestamp when both pinned.
        let bothPinned = ClipboardBackupImporter.mergedAnnotation(
            local: ClipboardAnnotationRecord(pinned: true, pinnedAt: late),
            imported: ClipboardAnnotationRecord(pinned: true, pinnedAt: early)
        )
        #expect(bothPinned.pinnedAt == early)
    }

    @Test func collectionsUnionByIDAndRenameOnNameCollision() throws {
        let sharedID = "col_SHARED"
        let local = ClipboardAnnotationsDocument(
            annotations: [:],
            collections: [
                ClipboardAnnotationCollection(id: sharedID, name: "Work", contentHashes: ["h1", "h2"]),
                ClipboardAnnotationCollection(id: "col_LOCAL2", name: "Reading", contentHashes: ["h3"])
            ]
        )
        let imported = ClipboardAnnotationsDocument(
            annotations: [:],
            collections: [
                ClipboardAnnotationCollection(id: sharedID, name: "Work Renamed", contentHashes: ["h2", "h4"]),
                ClipboardAnnotationCollection(id: "col_IMPORT2", name: "Reading", contentHashes: ["h5"]),
                ClipboardAnnotationCollection(id: "col_IMPORT3", name: "Fresh", contentHashes: [])
            ]
        )
        let result = ClipboardBackupImporter.mergeAnnotations(local: local, imported: imported)
        #expect(result.collectionsMergedByID == 1)
        #expect(result.collectionsRenamed == 1)
        #expect(result.collectionsAdded == 2)

        let shared = try #require(result.document.collections.first { $0.id == sharedID })
        #expect(shared.name == "Work") // local name wins
        #expect(shared.contentHashes == ["h1", "h2", "h4"]) // local order, unseen appended
        let renamed = try #require(result.document.collections.first { $0.id == "col_IMPORT2" })
        #expect(renamed.name == "Reading (imported)")
        #expect(result.document.collections.contains { $0.name == "Fresh" })
    }

    @Test func zeroLiveOccurrenceAnnotationsImportAnyway() throws {
        let fixture = try makeSourceFixture("orphanann")
        let target = try BackupTestSupport.temporaryDirectory("merge-orphanann-dst")
        _ = try BackupTestSupport.seedEvent(target, content: "unrelated clip")

        let importer = try makeImporter(target, label: "orphanann")
        let outcome = try importer.run(
            backupFileURL: fixture.backupFile,
            passphrase: BackupTestSupport.passphrase,
            options: ClipboardBackupImportOptions(merge: true),
            dryRun: false
        )
        #expect(outcome.plan.annotationsAdded == 1)
        #expect(outcome.plan.collectionsAdded == 1)
        let store = ClipboardAnnotationsStore(archiveRoot: target)
        let pinnedHash = fixture.events[0].contentHash
        #expect(store.annotation(for: pinnedHash)?.pinned == true)
        #expect(store.annotation(for: pinnedHash)?.tags == ["fixtures", "alpha"])
        #expect(store.collections().count == 1)
    }

    @Test func restoreWithoutMergeRequiresEmptyArchive() throws {
        let fixture = try makeSourceFixture("notempty")
        let target = try BackupTestSupport.temporaryDirectory("merge-notempty-dst")
        _ = try BackupTestSupport.seedEvent(target, content: "makes the archive non-empty")
        let before = try BackupTestSupport.treeSignature(target)

        let importer = try makeImporter(target, label: "notempty")
        #expect(throws: ClipboardBackupError.archiveNotEmpty) {
            _ = try importer.run(
                backupFileURL: fixture.backupFile,
                passphrase: BackupTestSupport.passphrase,
                options: ClipboardBackupImportOptions(merge: false),
                dryRun: false
            )
        }
        #expect(try BackupTestSupport.treeSignature(target) == before)
        #expect(BackupTestSupport.stagingDirectories(target).isEmpty)
    }

    @Test func dryRunAndExecuteShareOnePlan() throws {
        let fixture = try makeSourceFixture("parity")
        let templateTarget = try BackupTestSupport.temporaryDirectory("merge-parity-template")
        _ = try BackupTestSupport.seedEvent(templateTarget, content: "parity local clip")
        let dryTarget = try BackupTestSupport.temporaryDirectory("merge-parity-dry")
        let executeTarget = try BackupTestSupport.temporaryDirectory("merge-parity-exec")
        try BackupTestSupport.copyTree(templateTarget, to: dryTarget)
        try BackupTestSupport.copyTree(templateTarget, to: executeTarget)

        let dryBefore = try BackupTestSupport.treeSignature(dryTarget)
        let dryImporter = try makeImporter(dryTarget, label: "parity-dry")
        let dryOutcome = try dryImporter.run(
            backupFileURL: fixture.backupFile,
            passphrase: BackupTestSupport.passphrase,
            options: ClipboardBackupImportOptions(merge: true),
            dryRun: true
        )
        // Dry-run writes nothing and leaves no staging.
        #expect(try BackupTestSupport.treeSignature(dryTarget) == dryBefore)
        #expect(BackupTestSupport.stagingDirectories(dryTarget).isEmpty)

        let executeImporter = try makeImporter(executeTarget, label: "parity-exec")
        let executeOutcome = try executeImporter.run(
            backupFileURL: fixture.backupFile,
            passphrase: BackupTestSupport.passphrase,
            options: ClipboardBackupImportOptions(merge: true),
            dryRun: false
        )
        #expect(dryOutcome.plan == executeOutcome.plan)
        #expect(executeOutcome.plan.newEvents == 3)
    }

    // MARK: - Fault-injected commit rollback

    @Test func faultAtEveryCommitStepRollsBackByteIdentical() throws {
        struct InjectedFault: Error {}
        // A backup WITH settings so the .settings step actually mutates.
        let sourceRoot = try BackupTestSupport.temporaryDirectory("fault-src")
        let sourceIndex = try BackupTestSupport.temporaryDirectory("fault-src-idx")
            .appendingPathComponent("index.sqlite")
        try BackupTestSupport.seedMixedArchive(sourceRoot, indexURL: sourceIndex)
        let sourceSettingsURL = try BackupTestSupport.temporaryDirectory("fault-src-cfg")
            .appendingPathComponent("settings.json")
        var sourceSettings = ClipboardSettings()
        sourceSettings.recentItemLimit = 42
        try ClipboardSettingsStore(settingsURL: sourceSettingsURL).save(sourceSettings)
        let backupFile = try BackupTestSupport.temporaryDirectory("fault-out")
            .appendingPathComponent("fault.clipbak")
        _ = try BackupTestSupport.export(
            sourceRoot,
            to: backupFile,
            includeSettings: true,
            settingsURL: sourceSettingsURL
        )

        // Target template: pre-existing content AND a local settings file,
        // so every step (ledger append, day merge, annotations merge,
        // settings overwrite) has real work to undo.
        let template = try BackupTestSupport.temporaryDirectory("fault-template")
        _ = try BackupTestSupport.seedEvent(template, content: "fault target local clip")
        let templateAnnotations = ClipboardAnnotationsStore(archiveRoot: template)
        try templateAnnotations.setTags(["local-only"], forContentHash: "sha256:faultlocal")
        let templateSettingsURL = template.appendingPathComponent("../fault-template-settings.json").standardizedFileURL
        var targetSettings = ClipboardSettings()
        targetSettings.recentItemLimit = 11
        try ClipboardSettingsStore(settingsURL: templateSettingsURL).save(targetSettings)
        let settingsBytesBefore = try Data(contentsOf: templateSettingsURL)

        for step in ClipboardBackupCommitStep.allCases {
            let target = try BackupTestSupport.temporaryDirectory("fault-dst-\(step.rawValue)")
            try BackupTestSupport.copyTree(template, to: target)
            let settingsURL = try BackupTestSupport.temporaryDirectory("fault-cfg-\(step.rawValue)")
                .appendingPathComponent("settings.json")
            try settingsBytesBefore.write(to: settingsURL)
            let before = try BackupTestSupport.treeSignature(target)

            var importer = ClipboardBackupImporter(
                archiveRoot: target,
                indexURL: try BackupTestSupport.temporaryDirectory("fault-idx-\(step.rawValue)")
                    .appendingPathComponent("index.sqlite"),
                settingsURL: settingsURL
            )
            importer.commitFault = { current in
                if current == step {
                    throw InjectedFault()
                }
            }
            do {
                _ = try importer.run(
                    backupFileURL: backupFile,
                    passphrase: BackupTestSupport.passphrase,
                    options: ClipboardBackupImportOptions(merge: true, applySettings: true),
                    dryRun: false
                )
                Issue.record("step \(step.rawValue): fault did not propagate")
            } catch is InjectedFault {
                // expected
            }
            let after = try BackupTestSupport.treeSignature(target)
            #expect(after == before, "step \(step.rawValue): tree not byte-identical after rollback")
            #expect(
                try Data(contentsOf: settingsURL) == settingsBytesBefore,
                "step \(step.rawValue): settings file not restored"
            )
            #expect(
                BackupTestSupport.stagingDirectories(target).isEmpty,
                "step \(step.rawValue): staging left behind"
            )
        }
    }

    @Test func staleStagingRecoveryRestoresPreImageTree() throws {
        let fixture = try makeSourceFixture("stale")
        let target = try BackupTestSupport.temporaryDirectory("merge-stale-dst")
        _ = try BackupTestSupport.seedEvent(target, content: "stale-recovery local clip")
        let before = try BackupTestSupport.treeSignature(target)

        var importer = try makeImporter(target, label: "stale")
        // Simulate a hard kill right after the day-files step: mutations
        // are on disk, staging + journal remain, nothing rolled back.
        importer.commitFault = { step in
            if step == .dayFiles {
                throw ClipboardBackupSimulatedCrash()
            }
        }
        do {
            _ = try importer.run(
                backupFileURL: fixture.backupFile,
                passphrase: BackupTestSupport.passphrase,
                options: ClipboardBackupImportOptions(merge: true),
                dryRun: false
            )
            Issue.record("simulated crash did not propagate")
        } catch is ClipboardBackupSimulatedCrash {
            // expected
        }
        #expect(!BackupTestSupport.stagingDirectories(target).isEmpty)
        #expect(try BackupTestSupport.treeSignature(target) != before) // mutations landed

        // Next backup entry point finds and rolls back the stale staging.
        let recovered = try ClipboardBackupImporter.recoverStaleStaging(archiveRoot: target)
        #expect(recovered == 1)
        #expect(BackupTestSupport.stagingDirectories(target).isEmpty)
        #expect(try BackupTestSupport.treeSignature(target) == before)

        // And a fresh import afterwards works normally end-to-end.
        importer.commitFault = nil
        let outcome = try importer.run(
            backupFileURL: fixture.backupFile,
            passphrase: BackupTestSupport.passphrase,
            options: ClipboardBackupImportOptions(merge: true),
            dryRun: false
        )
        #expect(outcome.plan.newEvents == 3)
    }

    @Test func unreadableLinesAreCountedAndSkippedInMergeMode() throws {
        let sourceRoot = try BackupTestSupport.temporaryDirectory("garbage-src")
        let seeded = try BackupTestSupport.seedEvent(sourceRoot, content: "good line fixture")
        // Hand-append a corrupt line to the source day file.
        let reader = ClipboardArchiveReader(archiveRoot: sourceRoot)
        let dayFile = try #require(try reader.eventFiles().first)
        let handle = try FileHandle(forWritingTo: dayFile)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("{\"broken json line\n".utf8))
        try handle.close()
        let backupFile = try BackupTestSupport.temporaryDirectory("garbage-out")
            .appendingPathComponent("garbage.clipbak")
        _ = try BackupTestSupport.export(sourceRoot, to: backupFile)

        let target = try BackupTestSupport.temporaryDirectory("garbage-dst")
        _ = try BackupTestSupport.seedEvent(target, content: "target local clip")
        let importer = try makeImporter(target, label: "garbage")
        let outcome = try importer.run(
            backupFileURL: backupFile,
            passphrase: BackupTestSupport.passphrase,
            options: ClipboardBackupImportOptions(merge: true),
            dryRun: false
        )
        #expect(outcome.plan.unreadableLines == 1)
        #expect(outcome.plan.newEvents == 1)
        let targetReader = ClipboardArchiveReader(archiveRoot: target)
        #expect(try targetReader.event(withID: seeded.id)?.id == seeded.id)
        // The corrupt line did not propagate.
        let corruptPropagated = try targetReader.eventFiles().contains { url in
            try String(contentsOf: url).contains("broken json line")
        }
        #expect(!corruptPropagated)
    }
}
