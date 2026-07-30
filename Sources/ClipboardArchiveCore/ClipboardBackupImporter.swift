import CryptoKit
import Foundation

// Slice 8: restore/import for CLIPBAK1 backups. Three phases:
//
//   A  authenticate + stage: decrypt every entry into a hidden 0700
//      `.backup-staging-<uuid>/` directory inside the archive root. Every
//      entry path is allowlist- and containment-validated BEFORE any file
//      is created; every chunk's GCM tag, positional AAD, framing, and the
//      per-entry sha256 are verified. Any failure deletes staging; the
//      archive is untouched.
//   B  plan: snapshot local ids/ledger/annotations, apply the merge
//      semantics table, produce the preview. Dry-run stops here. Dry-run
//      and execute share this one planner (parity by construction).
//   C  journaled commit, in order: journal -> pre-images -> LEDGER FIRST
//      (fail-closed: a crash after the ledger step can only over-suppress,
//      never resurrect) -> bodies (additive) -> event day files (atomic
//      replace each) -> annotations -> format marker -> settings (opt-in)
//      -> index full rebuild (failure = "run repair-index", no rollback)
//      -> delete staging. Any error in the journaled steps rolls back from
//      pre-images to a byte-identical tree. Stale staging with a journal is
//      detected at the next backup entry point and rolled back first.

public enum ClipboardBackupCommitStep: String, CaseIterable, Sendable {
    case journal
    case preImages
    case ledger
    case bodies
    case dayFiles
    case annotations
    case formatMarker
    case settings
}

/// Thrown only by test fault injectors to simulate a hard kill: the
/// importer rethrows it WITHOUT rolling back or cleaning staging, leaving
/// the on-disk state a crash would leave.
struct ClipboardBackupSimulatedCrash: Error {}

public struct ClipboardBackupImportOptions: Sendable {
    public var merge: Bool
    public var applySettings: Bool

    public init(merge: Bool, applySettings: Bool = false) {
        self.merge = merge
        self.applySettings = applySettings
    }
}

/// The truthful preview: every count is produced by the same planner that
/// the real commit executes (dry-run == execute parity).
public struct ClipboardBackupImportPlan: Codable, Equatable, Sendable {
    public var mode: String
    public var backupID: String
    public var backupCreatedAt: Date
    public var includesSettings: Bool

    public var newEvents: Int
    public var skippedExistingEvents: Int
    /// Ids present in the LOCAL deletion ledger: local deletion is
    /// authoritative — restore never resurrects. Content is NOT written.
    public var skippedDeletedHere: Int
    public var newTombstones: Int
    public var unreadableLines: Int

    public var ledgerRecordsToAdd: Int
    /// Backup ledger records whose id is currently LIVE locally: the union
    /// will newly suppress these local events.
    public var locallyLiveNewlySuppressed: Int

    public var blockedLinesToAppend: Int
    public var blockedLinesSkippedIdentical: Int

    public var bodiesToAdd: Int
    public var bodiesSkippedIdentical: Int
    public var bodiesSkippedDeletedHere: Int

    public var manifestFilesToAdd: Int
    public var manifestFilesSkipped: Int

    public var annotationsAdded: Int
    public var annotationsMerged: Int
    public var annotationConflictsLocalWins: Int
    public var collectionsAdded: Int
    public var collectionsMergedByID: Int
    public var collectionsRenamed: Int

    public var settingsWillApply: Bool
    public var filesNotIncludedInBackup: [String]
}

/// Phase A+B result held between preview and commit. The staging directory
/// holds decrypted plaintext, owner-only (0700/0600), inside the archive
/// root (same volume and protection class as the archive itself).
public struct ClipboardBackupPreparedImport: Sendable {
    public var plan: ClipboardBackupImportPlan
    public var manifest: ClipboardBackupManifest
    public var stagingURL: URL
    var work: ClipboardBackupWorkItems
}

struct ClipboardBackupWorkItems: Sendable {
    var verbatimCopyAll: Bool
    /// Staged relative paths, by commit step, in deterministic order.
    var ledgerAppends: [(path: String, lines: [Data])]
    var additiveCopies: [String]
    var dayFileAppends: [(path: String, lines: [Data])]
    /// Encoded merged annotations document (merge mode, only when changed).
    var annotationsMergedData: Data?
    /// Staged annotations path to copy verbatim (restore-empty mode).
    var annotationsVerbatimPath: String?
    var formatMarkerStagedPath: String?
    var settingsStagedPath: String?
}

struct ClipboardBackupJournal: Codable {
    var status: String // staging | mutating | done
    var mutatedFiles: [String]
    var createdFiles: [String]
    var settingsMutated: Bool
    var settingsCreated: Bool
    var settingsPath: String?
}

public struct ClipboardBackupImportOutcome: Sendable {
    public var plan: ClipboardBackupImportPlan
    public var indexedCount: Int?
    public var indexRebuildFailed: Bool
    public var appliedSettings: Bool
}

public struct ClipboardBackupImporter: Sendable {
    public var archiveRoot: URL
    public var indexURL: URL
    public var settingsURL: URL
    /// Test-only fault injector, called after each commit step completes.
    public var commitFault: (@Sendable (ClipboardBackupCommitStep) throws -> Void)?

    static let stagingPrefix = ".backup-staging-"
    static let journalFileName = "journal.json"
    static let preImagesDirectoryName = "pre-images"
    static let settingsPreImageName = "pre-image-settings.json"

    public init(
        archiveRoot: URL,
        indexURL: URL = ClipboardDefaults.indexURL(),
        settingsURL: URL = ClipboardDefaults.settingsURL()
    ) {
        self.archiveRoot = archiveRoot
        self.indexURL = indexURL
        self.settingsURL = settingsURL
    }

    // MARK: - Phase A + B

    /// Authenticates, stages, and plans. Callers preview `plan`, then either
    /// `commit(_:)` or `discard(_:)`. Recovers stale staging first.
    public func plan(
        backupFileURL: URL,
        passphrase: Data,
        options: ClipboardBackupImportOptions,
        progress: (@Sendable (Int64, Int64) -> Void)? = nil
    ) throws -> ClipboardBackupPreparedImport {
        _ = try Self.recoverStaleStaging(archiveRoot: archiveRoot)

        let staged = try stage(backupFileURL: backupFileURL, passphrase: passphrase, progress: progress)
        do {
            let prepared = try buildPlan(staged: staged, options: options)
            return prepared
        } catch {
            try? FileManager.default.removeItem(at: staged.stagingURL)
            throw error
        }
    }

    public func discard(_ prepared: ClipboardBackupPreparedImport) {
        try? FileManager.default.removeItem(at: prepared.stagingURL)
    }

    /// One-call convenience: plan then (unless dry-run) commit.
    public func run(
        backupFileURL: URL,
        passphrase: Data,
        options: ClipboardBackupImportOptions,
        dryRun: Bool
    ) throws -> ClipboardBackupImportOutcome {
        let prepared = try plan(backupFileURL: backupFileURL, passphrase: passphrase, options: options)
        if dryRun {
            discard(prepared)
            return ClipboardBackupImportOutcome(
                plan: prepared.plan,
                indexedCount: nil,
                indexRebuildFailed: false,
                appliedSettings: false
            )
        }
        return try commit(prepared)
    }

    // MARK: - Staging (phase A)

    struct StagedBackup {
        var manifest: ClipboardBackupManifest
        var stagingURL: URL
    }

    private func stage(
        backupFileURL: URL,
        passphrase: Data,
        progress: (@Sendable (Int64, Int64) -> Void)?
    ) throws -> StagedBackup {
        let reader = try ClipboardBackupContainerReader(fileURL: backupFileURL)
        defer { reader.close() }
        let keys = try reader.deriveKeys(passphrase: passphrase)
        let manifest = try reader.openManifest(keys: keys)

        let fileManager = FileManager.default
        if !fileManager.fileExists(atPath: archiveRoot.path) {
            try fileManager.createDirectory(
                at: archiveRoot,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: NSNumber(value: Int16(0o700))]
            )
        }
        let stagingURL = archiveRoot.appendingPathComponent(
            Self.stagingPrefix + UUID().uuidString,
            isDirectory: true
        )
        try fileManager.createDirectory(
            at: stagingURL,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: NSNumber(value: Int16(0o700))]
        )
        var stagingSucceeded = false
        defer {
            if !stagingSucceeded {
                try? fileManager.removeItem(at: stagingURL)
            }
        }
        try writeJournal(
            ClipboardBackupJournal(
                status: "staging",
                mutatedFiles: [],
                createdFiles: [],
                settingsMutated: false,
                settingsCreated: false,
                settingsPath: nil
            ),
            stagingURL: stagingURL
        )

        // Validate EVERY entry path before creating any file.
        var seenPaths = Set<String>()
        var stagedURLs: [URL] = []
        for entry in manifest.entries {
            guard Self.isAllowlistedEntryPath(entry.path) else {
                throw ClipboardBackupError.entryPathRejected(entry.path)
            }
            guard seenPaths.insert(entry.path).inserted else {
                throw ClipboardBackupError.entryPathRejected(entry.path)
            }
            guard let stagedURL = try? ClipboardArchivePath.containedURL(
                relativePath: entry.path,
                archiveRoot: stagingURL
            ) else {
                throw ClipboardBackupError.entryPathRejected(entry.path)
            }
            stagedURLs.append(stagedURL)
        }

        // Pre-create every staged file empty (0600) so zero-chunk entries
        // exist, then append verified chunks in container order.
        for stagedURL in stagedURLs {
            try ClipboardPrivateFileSystem.createDirectory(
                stagedURL.deletingLastPathComponent(),
                archiveRoot: stagingURL
            )
            guard fileManager.createFile(
                atPath: stagedURL.path,
                contents: nil,
                attributes: [.posixPermissions: NSNumber(value: Int16(0o600))]
            ) else {
                throw ClipboardBackupError.ioFailure("cannot create staged file")
            }
        }

        var currentEntryIndex = -1
        var currentHandle: FileHandle?
        var currentHasher = SHA256()
        var currentBytes: Int64 = 0
        var processedBytes: Int64 = 0
        let totalBytes = manifest.totalPlaintextBytes

        func finishCurrentEntry() throws {
            guard currentEntryIndex >= 0 else {
                return
            }
            try currentHandle?.close()
            currentHandle = nil
            let entry = manifest.entries[currentEntryIndex]
            let digest = "sha256:" + currentHasher.finalize().map { String(format: "%02x", $0) }.joined()
            guard currentBytes == entry.bytes, digest == entry.sha256 else {
                throw ClipboardBackupError.entryHashMismatch(entry.path)
            }
        }

        try reader.walkChunks(manifest: manifest, keys: keys) { entryIndex, _, plaintext in
            if entryIndex != currentEntryIndex {
                try finishCurrentEntry()
                currentEntryIndex = entryIndex
                currentHasher = SHA256()
                currentBytes = 0
                currentHandle = try FileHandle(forWritingTo: stagedURLs[entryIndex])
            }
            currentHasher.update(data: plaintext)
            currentBytes += Int64(plaintext.count)
            try currentHandle?.write(contentsOf: plaintext)
            processedBytes += Int64(plaintext.count)
            progress?(processedBytes, totalBytes)
        }
        try finishCurrentEntry()

        // Zero-chunk entries never passed through the walk: verify them too.
        for (index, entry) in manifest.entries.enumerated() where entry.chunkCount == 0 {
            let (digest, bytes) = try ClipboardBackupHashing.sha256OfFile(at: stagedURLs[index])
            guard bytes == 0, digest == entry.sha256 else {
                throw ClipboardBackupError.entryHashMismatch(entry.path)
            }
        }

        stagingSucceeded = true
        return StagedBackup(manifest: manifest, stagingURL: stagingURL)
    }

    static func isAllowlistedEntryPath(_ path: String) -> Bool {
        if path == "archive-format.json" || path == ClipboardBackupFormat.settingsEntryPath {
            return true
        }
        let allowedPrefixes = ["raw/", "deletion-ledger/", "annotations/", "manifests/"]
        guard allowedPrefixes.contains(where: { path.hasPrefix($0) }) else {
            return false
        }
        // No traversal, no absolute paths, no hidden components (protects
        // journal/pre-image staging internals and keeps enumeration honest).
        let components = (path as NSString).pathComponents
        guard !path.hasPrefix("/"), !components.contains(".."), !components.contains("."),
              !components.contains(where: { $0.hasPrefix(".") }), !components.contains("") else {
            return false
        }
        return true
    }

    // MARK: - Planning (phase B)

    private func buildPlan(
        staged: StagedBackup,
        options: ClipboardBackupImportOptions
    ) throws -> ClipboardBackupPreparedImport {
        let manifest = staged.manifest
        let stagingURL = staged.stagingURL
        let fileManager = FileManager.default
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let localReader = ClipboardArchiveReader(archiveRoot: archiveRoot)
        let localEventFiles = try localReader.eventFiles()
        let localLedgerIDs = try ClipboardDeletionLedger(archiveRoot: archiveRoot).deletedIDs()
        let annotationsStore = ClipboardAnnotationsStore(archiveRoot: archiveRoot)
        let localAnnotationsExist = fileManager.fileExists(atPath: annotationsStore.annotationsFileURL.path)

        if !options.merge {
            // Restore-without-merge requires an empty archive: no event
            // files, no deletion ledger, no annotations. No "replace" mode
            // exists — compose prune/redact first.
            let ledgerDir = archiveRoot.appendingPathComponent("deletion-ledger")
            let ledgerEntries = (try? fileManager.contentsOfDirectory(atPath: ledgerDir.path)) ?? []
            guard localEventFiles.isEmpty,
                  ledgerEntries.filter({ !$0.hasPrefix(".") }).isEmpty,
                  !localAnnotationsExist else {
                throw ClipboardBackupError.archiveNotEmpty
            }
        }

        // Local snapshot: every stored id (live + tombstone), live ids, and
        // the raw line set per day file (blocked-line idempotence).
        var localEventIDs = Set<String>()
        var localLiveEventIDs = Set<String>()
        var localLinesByDayFile: [String: Set<Data>] = [:]
        let rootPath = archiveRoot.standardizedFileURL.path
        for fileURL in localEventFiles {
            let relative = String(fileURL.standardizedFileURL.path.dropFirst(rootPath.count + 1))
            var lineSet = Set<Data>()
            for line in try String(contentsOf: fileURL).split(separator: "\n", omittingEmptySubsequences: true) {
                guard let data = String(line).data(using: .utf8) else {
                    continue
                }
                lineSet.insert(data)
                if let event = try? decoder.decode(StoredClipboardEvent.self, from: data) {
                    localEventIDs.insert(event.id)
                    if event.privacyLabel != .doNotIndex, !localLedgerIDs.contains(event.id) {
                        localLiveEventIDs.insert(event.id)
                    }
                }
            }
            localLinesByDayFile[relative] = lineSet
        }

        var plan = ClipboardBackupImportPlan(
            mode: options.merge ? "merge" : "restore-empty",
            backupID: manifest.backupID,
            backupCreatedAt: manifest.createdAt,
            includesSettings: manifest.includesSettings,
            newEvents: 0,
            skippedExistingEvents: 0,
            skippedDeletedHere: 0,
            newTombstones: 0,
            unreadableLines: 0,
            ledgerRecordsToAdd: 0,
            locallyLiveNewlySuppressed: 0,
            blockedLinesToAppend: 0,
            blockedLinesSkippedIdentical: 0,
            bodiesToAdd: 0,
            bodiesSkippedIdentical: 0,
            bodiesSkippedDeletedHere: 0,
            manifestFilesToAdd: 0,
            manifestFilesSkipped: 0,
            annotationsAdded: 0,
            annotationsMerged: 0,
            annotationConflictsLocalWins: 0,
            collectionsAdded: 0,
            collectionsMergedByID: 0,
            collectionsRenamed: 0,
            settingsWillApply: options.applySettings,
            filesNotIncludedInBackup: manifest.filesNotIncluded
        )
        if options.applySettings, !manifest.includesSettings {
            throw ClipboardBackupError.backupHasNoSettings
        }

        var work = ClipboardBackupWorkItems(
            verbatimCopyAll: !options.merge,
            ledgerAppends: [],
            additiveCopies: [],
            dayFileAppends: [],
            annotationsMergedData: nil,
            annotationsVerbatimPath: nil,
            formatMarkerStagedPath: nil,
            settingsStagedPath: nil
        )

        let entriesByKind = Dictionary(grouping: manifest.entries, by: \.kind)

        // Events: decide per line. Deleted-here decisions also veto the
        // matching staged body files (content must NOT come back).
        var deletedHereBodyPaths = Set<String>()
        var dayAppends: [String: [Data]] = [:]
        for entry in (entriesByKind["events"] ?? []).sorted(by: { $0.path < $1.path }) {
            let stagedFile = stagingURL.appendingPathComponent(entry.path)
            for line in try String(contentsOf: stagedFile).split(separator: "\n", omittingEmptySubsequences: true) {
                guard let data = String(line).data(using: .utf8) else {
                    plan.unreadableLines += 1
                    continue
                }
                if let event = try? decoder.decode(StoredClipboardEvent.self, from: data) {
                    if localLedgerIDs.contains(event.id) {
                        plan.skippedDeletedHere += 1
                        if let bodyPath = event.rawContentPath {
                            deletedHereBodyPaths.insert(bodyPath)
                        }
                    } else if localEventIDs.contains(event.id) {
                        plan.skippedExistingEvents += 1
                    } else {
                        let target = Self.dayFileRelativePath(for: event.capturedAt)
                        dayAppends[target, default: []].append(data)
                        if event.privacyLabel == .doNotIndex {
                            plan.newTombstones += 1
                        } else {
                            plan.newEvents += 1
                        }
                        localEventIDs.insert(event.id)
                    }
                } else if let blocked = try? decoder.decode(BlockedClipboardEvent.self, from: data),
                          blocked.eventType == "blocked_sensitive_clipboard_item" {
                    let target = Self.dayFileRelativePath(for: blocked.capturedAt)
                    if localLinesByDayFile[target]?.contains(data) == true {
                        plan.blockedLinesSkippedIdentical += 1
                    } else {
                        dayAppends[target, default: []].append(data)
                        localLinesByDayFile[target, default: []].insert(data)
                        plan.blockedLinesToAppend += 1
                    }
                } else {
                    plan.unreadableLines += 1
                }
            }
        }
        work.dayFileAppends = dayAppends.sorted { $0.key < $1.key }.map { ($0.key, $0.value) }

        // Ledger union: deletions are never undone; missing records append
        // to their same-named day file. Locally-live ids that will become
        // suppressed are called out separately.
        var ledgerAppends: [String: [Data]] = [:]
        var backupLedgerIDsSeen = Set<String>()
        for entry in (entriesByKind["ledger"] ?? []).sorted(by: { $0.path < $1.path }) {
            let stagedFile = stagingURL.appendingPathComponent(entry.path)
            for line in try String(contentsOf: stagedFile).split(separator: "\n", omittingEmptySubsequences: true) {
                guard let data = String(line).data(using: .utf8),
                      let record = try? decoder.decode(ClipboardDeletionEvent.self, from: data) else {
                    plan.unreadableLines += 1
                    continue
                }
                guard !localLedgerIDs.contains(record.clipboardEventID),
                      backupLedgerIDsSeen.insert(record.clipboardEventID).inserted else {
                    continue
                }
                ledgerAppends[entry.path, default: []].append(data)
                plan.ledgerRecordsToAdd += 1
                if localLiveEventIDs.contains(record.clipboardEventID) {
                    plan.locallyLiveNewlySuppressed += 1
                }
            }
        }
        work.ledgerAppends = ledgerAppends.sorted { $0.key < $1.key }.map { ($0.key, $0.value) }

        // Additive files: bodies (and raw-other), historical manifests,
        // annotation aside files. Local body with a DIFFERENT hash is a
        // corruption signal: the whole import aborts pre-write.
        let additiveKinds = ["body", "raw-other", "manifest", "annotations-other"]
        for kind in additiveKinds {
            for entry in (entriesByKind[kind] ?? []).sorted(by: { $0.path < $1.path }) {
                let isBodyKind = kind == "body" || kind == "raw-other"
                if isBodyKind, deletedHereBodyPaths.contains(entry.path) {
                    plan.bodiesSkippedDeletedHere += 1
                    continue
                }
                guard let localURL = try? ClipboardArchivePath.containedURL(
                    relativePath: entry.path,
                    archiveRoot: archiveRoot
                ) else {
                    throw ClipboardBackupError.entryPathRejected(entry.path)
                }
                if fileManager.fileExists(atPath: localURL.path) {
                    let (localHash, _) = try ClipboardBackupHashing.sha256OfFile(at: localURL)
                    if localHash == entry.sha256 {
                        if isBodyKind {
                            plan.bodiesSkippedIdentical += 1
                        } else {
                            plan.manifestFilesSkipped += 1
                        }
                    } else if isBodyKind {
                        throw ClipboardBackupError.divergentBodyContent(entry.path)
                    } else {
                        // Historical manifests/aside files: local wins.
                        plan.manifestFilesSkipped += 1
                    }
                } else {
                    work.additiveCopies.append(entry.path)
                    if isBodyKind {
                        plan.bodiesToAdd += 1
                    } else {
                        plan.manifestFilesToAdd += 1
                    }
                }
            }
        }

        // Annotations: pinned=OR (earlier pinnedAt), tags=union, snippet=OR,
        // title/sensitivity=local wins, expiry=earlier; collections union by
        // id with rename on name collision. Zero-live-occurrence annotations
        // import anyway.
        if let annotationsEntry = (entriesByKind["annotations"] ?? []).first {
            let stagedFile = stagingURL.appendingPathComponent(annotationsEntry.path)
            if options.merge {
                let importedDocument = (try? decoder.decode(
                    ClipboardAnnotationsDocument.self,
                    from: Data(contentsOf: stagedFile)
                )) ?? ClipboardAnnotationsDocument(updatedAt: .distantPast)
                let localDocument = annotationsStore.document()
                let mergeResult = Self.mergeAnnotations(local: localDocument, imported: importedDocument)
                plan.annotationsAdded = mergeResult.added
                plan.annotationsMerged = mergeResult.merged
                plan.annotationConflictsLocalWins = mergeResult.conflictsLocalWins
                plan.collectionsAdded = mergeResult.collectionsAdded
                plan.collectionsMergedByID = mergeResult.collectionsMergedByID
                plan.collectionsRenamed = mergeResult.collectionsRenamed
                if mergeResult.changed {
                    let encoder = JSONEncoder()
                    encoder.dateEncodingStrategy = .iso8601
                    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
                    work.annotationsMergedData = try encoder.encode(mergeResult.document)
                }
            } else {
                work.annotationsVerbatimPath = annotationsEntry.path
                if let importedDocument = try? decoder.decode(
                    ClipboardAnnotationsDocument.self,
                    from: Data(contentsOf: stagedFile)
                ) {
                    plan.annotationsAdded = importedDocument.annotations.count
                    plan.collectionsAdded = importedDocument.collections.count
                }
            }
        }

        if let markerEntry = (entriesByKind["format-marker"] ?? []).first {
            work.formatMarkerStagedPath = markerEntry.path
        }
        if let settingsEntry = (entriesByKind["settings"] ?? []).first {
            work.settingsStagedPath = settingsEntry.path
        }

        return ClipboardBackupPreparedImport(
            plan: plan,
            manifest: manifest,
            stagingURL: stagingURL,
            work: work
        )
    }

    // MARK: - Merge helpers (shared by planner and tests)

    /// One annotation record merged per the semantics table. Privacy always
    /// wins ties: pins OR together, expiry takes the EARLIER date, and
    /// local text (title/sensitivity) is never overwritten.
    public static func mergedAnnotation(
        local: ClipboardAnnotationRecord,
        imported: ClipboardAnnotationRecord
    ) -> ClipboardAnnotationRecord {
        var merged = ClipboardAnnotationRecord()
        merged.pinned = local.pinned || imported.pinned
        merged.pinnedAt = [local.pinnedAt, imported.pinnedAt].compactMap { $0 }.min()
        if !merged.pinned {
            merged.pinnedAt = nil
        }
        merged.tags = ClipboardAnnotationsStore.normalizedTags(local.tags + imported.tags)
        merged.snippet = local.snippet || imported.snippet
        merged.snippetTitle = local.snippetTitle ?? imported.snippetTitle
        merged.sensitivityOverride = local.sensitivityOverride ?? imported.sensitivityOverride
        merged.expiresAt = [local.expiresAt, imported.expiresAt].compactMap { $0 }.min()
        if merged.snippet, !merged.pinned {
            // Invariant: snippet implies pinned.
            merged.pinned = true
            merged.pinnedAt = merged.pinnedAt ?? [local.pinnedAt, imported.pinnedAt].compactMap { $0 }.min()
        }
        return merged
    }

    struct AnnotationsMergeResult {
        var document: ClipboardAnnotationsDocument
        var changed: Bool
        var added: Int
        var merged: Int
        var conflictsLocalWins: Int
        var collectionsAdded: Int
        var collectionsMergedByID: Int
        var collectionsRenamed: Int
    }

    static func mergeAnnotations(
        local: ClipboardAnnotationsDocument,
        imported: ClipboardAnnotationsDocument
    ) -> AnnotationsMergeResult {
        var document = local
        var added = 0
        var mergedCount = 0
        var conflicts = 0

        for (contentHash, importedRecord) in imported.annotations.sorted(by: { $0.key < $1.key }) {
            if importedRecord.isDefault {
                continue
            }
            if let localRecord = document.annotations[contentHash] {
                let merged = mergedAnnotation(local: localRecord, imported: importedRecord)
                if merged != localRecord {
                    mergedCount += 1
                }
                if (localRecord.snippetTitle != nil && importedRecord.snippetTitle != nil
                        && localRecord.snippetTitle != importedRecord.snippetTitle)
                    || (localRecord.sensitivityOverride != nil && importedRecord.sensitivityOverride != nil
                        && localRecord.sensitivityOverride != importedRecord.sensitivityOverride) {
                    conflicts += 1
                }
                document.annotations[contentHash] = merged
            } else {
                document.annotations[contentHash] = importedRecord
                added += 1
            }
        }

        var collectionsAdded = 0
        var collectionsMergedByID = 0
        var collectionsRenamed = 0
        for importedCollection in imported.collections {
            if let index = document.collections.firstIndex(where: { $0.id == importedCollection.id }) {
                // Same id: local name and order win; unseen members append.
                var localCollection = document.collections[index]
                let known = Set(localCollection.contentHashes)
                let appended = importedCollection.contentHashes.filter { !known.contains($0) }
                if !appended.isEmpty {
                    localCollection.contentHashes.append(contentsOf: appended)
                    document.collections[index] = localCollection
                }
                collectionsMergedByID += 1
            } else {
                var incoming = importedCollection
                let existingNames = Set(document.collections.map(\.name))
                if existingNames.contains(incoming.name) {
                    var candidate = "\(incoming.name) (imported)"
                    var suffix = 2
                    while existingNames.contains(candidate) {
                        candidate = "\(incoming.name) (imported \(suffix))"
                        suffix += 1
                    }
                    incoming.name = candidate
                    collectionsRenamed += 1
                }
                document.collections.append(incoming)
                collectionsAdded += 1
            }
        }

        let changed = document.annotations != local.annotations || document.collections != local.collections
        if changed {
            document.annotationsVersion = ClipboardAnnotationsDocument.currentVersion
            document.updatedAt = Date()
        }
        return AnnotationsMergeResult(
            document: document,
            changed: changed,
            added: added,
            merged: mergedCount,
            conflictsLocalWins: conflicts,
            collectionsAdded: collectionsAdded,
            collectionsMergedByID: collectionsMergedByID,
            collectionsRenamed: collectionsRenamed
        )
    }

    // MARK: - Commit (phase C)

    public func commit(_ prepared: ClipboardBackupPreparedImport) throws -> ClipboardBackupImportOutcome {
        let fileManager = FileManager.default
        let stagingURL = prepared.stagingURL
        let work = prepared.work
        let preImagesURL = stagingURL.appendingPathComponent(Self.preImagesDirectoryName, isDirectory: true)

        // Every path this commit will touch, split into "existing file we
        // will mutate" (pre-imaged) and "file we will create" (deleted on
        // rollback).
        var mutatedFiles: [String] = []
        var createdFiles: [String] = []

        func classify(_ relativePath: String) throws {
            let url = try containedArchiveURL(relativePath)
            if fileManager.fileExists(atPath: url.path) {
                if !mutatedFiles.contains(relativePath) {
                    mutatedFiles.append(relativePath)
                }
            } else if !createdFiles.contains(relativePath) {
                createdFiles.append(relativePath)
            }
        }

        if work.verbatimCopyAll {
            for entry in prepared.manifest.entries where entry.kind != "settings" {
                try classify(entry.path)
            }
        } else {
            for (path, _) in work.ledgerAppends {
                try classify(path)
            }
            for path in work.additiveCopies {
                try classify(path)
            }
            for (path, _) in work.dayFileAppends {
                try classify(path)
            }
            if work.annotationsMergedData != nil {
                try classify("annotations/annotations.json")
            }
        }
        let markerExists = fileManager.fileExists(
            atPath: archiveRoot.appendingPathComponent("archive-format.json").path
        )
        // The default-marker write in step 7 fires only when the backup has
        // content but no marker of its own (pre-marker source archive). An
        // empty backup must restore to an empty tree, byte-identical.
        let willWriteMarker = !markerExists && !prepared.manifest.entries.isEmpty
        if willWriteMarker {
            try classify("archive-format.json")
        }

        let willApplySettings = prepared.plan.settingsWillApply && work.settingsStagedPath != nil
        let settingsExists = fileManager.fileExists(atPath: settingsURL.path)

        var journal = ClipboardBackupJournal(
            status: "staging",
            mutatedFiles: mutatedFiles,
            createdFiles: createdFiles,
            settingsMutated: willApplySettings && settingsExists,
            settingsCreated: willApplySettings && !settingsExists,
            settingsPath: willApplySettings ? settingsURL.path : nil
        )

        var indexedCount: Int?
        var indexRebuildFailed = false
        var appliedSettings = false

        do {
            // Step 1: journal.
            try writeJournal(journal, stagingURL: stagingURL)
            try commitFault?(.journal)

            // Step 2: pre-images, then flip the journal to "mutating" —
            // rollback only ever restores once this status is on disk.
            try fileManager.createDirectory(
                at: preImagesURL,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: NSNumber(value: Int16(0o700))]
            )
            for relativePath in mutatedFiles {
                try copyPreImage(relativePath: relativePath, preImagesURL: preImagesURL)
            }
            if journal.settingsMutated {
                try fileManager.copyItem(
                    at: settingsURL,
                    to: stagingURL.appendingPathComponent(Self.settingsPreImageName)
                )
            }
            journal.status = "mutating"
            try writeJournal(journal, stagingURL: stagingURL)
            try commitFault?(.preImages)

            // Step 3: LEDGER FIRST. Fail-closed: a crash after this step can
            // only over-suppress, never resurrect deleted content.
            if work.verbatimCopyAll {
                for entry in prepared.manifest.entries where entry.kind == "ledger" {
                    try copyStagedFile(entry.path, stagingURL: stagingURL, preImagesURL: preImagesURL)
                }
            } else {
                for (relativePath, lines) in work.ledgerAppends {
                    try refreshPreImage(relativePath: relativePath, preImagesURL: preImagesURL)
                    try appendLines(lines, toRelativePath: relativePath)
                }
            }
            try commitFault?(.ledger)

            // Step 4: bodies and other additive files.
            if work.verbatimCopyAll {
                let additiveKinds: Set<String> = ["body", "raw-other", "manifest", "annotations-other"]
                for entry in prepared.manifest.entries where additiveKinds.contains(entry.kind) {
                    try copyStagedFile(entry.path, stagingURL: stagingURL, preImagesURL: preImagesURL)
                }
            } else {
                for relativePath in work.additiveCopies {
                    try copyStagedFile(relativePath, stagingURL: stagingURL, preImagesURL: preImagesURL)
                }
            }
            try commitFault?(.bodies)

            // Step 5: event day files, atomic replace each, with a
            // just-in-time pre-image refresh so lines captured since the
            // preview survive a rollback.
            if work.verbatimCopyAll {
                for entry in prepared.manifest.entries where entry.kind == "events" {
                    try copyStagedFile(entry.path, stagingURL: stagingURL, preImagesURL: preImagesURL)
                }
            } else {
                for (relativePath, lines) in work.dayFileAppends {
                    try refreshPreImage(relativePath: relativePath, preImagesURL: preImagesURL)
                    try appendLinesAtomically(lines, toRelativePath: relativePath)
                }
            }
            try commitFault?(.dayFiles)

            // Step 6: annotations.
            if work.verbatimCopyAll {
                if let path = work.annotationsVerbatimPath {
                    try copyStagedFile(path, stagingURL: stagingURL, preImagesURL: preImagesURL)
                }
            } else if let mergedData = work.annotationsMergedData {
                try refreshPreImage(relativePath: "annotations/annotations.json", preImagesURL: preImagesURL)
                try writeFileAtomically(mergedData, toRelativePath: "annotations/annotations.json")
            }
            try commitFault?(.annotations)

            // Step 7: archive format marker (never overwrites an existing one).
            if willWriteMarker, !fileManager.fileExists(
                atPath: archiveRoot.appendingPathComponent("archive-format.json").path
            ) {
                if let stagedPath = work.formatMarkerStagedPath {
                    try copyStagedFile(stagedPath, stagingURL: stagingURL, preImagesURL: preImagesURL)
                } else {
                    let marker = Data("{\"archiveFormatVersion\":1,\"minReader\":1}\n".utf8)
                    try writeFileAtomically(marker, toRelativePath: "archive-format.json")
                }
            }
            try commitFault?(.formatMarker)

            // Step 8: settings, opt-in only, through the tolerant decoder
            // and the settings store (never raw bytes).
            if willApplySettings, let stagedPath = work.settingsStagedPath {
                let stagedFile = stagingURL.appendingPathComponent(stagedPath)
                let data = try Data(contentsOf: stagedFile)
                guard let settings = Self.decodeSettings(data) else {
                    throw ClipboardBackupError.ioFailure("backup settings could not be decoded")
                }
                try ClipboardSettingsStore(settingsURL: settingsURL).save(settings)
                appliedSettings = true
            }
            try commitFault?(.settings)

            journal.status = "done"
            try writeJournal(journal, stagingURL: stagingURL)
        } catch let crash as ClipboardBackupSimulatedCrash {
            // Test-only: behave like a hard kill — leave staging + journal
            // exactly as they are for stale-staging recovery to find.
            throw crash
        } catch {
            try? Self.rollback(journal: journal, stagingURL: stagingURL, archiveRoot: archiveRoot)
            try? fileManager.removeItem(at: stagingURL)
            throw error
        }

        // Ledger cache: the deletion-ledger cache is signature-validated
        // (file size + mtime), so the appends above invalidate it inherently
        // on the next read.

        // Index full rebuild. Failure never rolls data back — the archive is
        // correct; the user is told to run repair-index.
        do {
            indexedCount = try ClipboardDerivedIndex(archiveRoot: archiveRoot, indexURL: indexURL).rebuild()
        } catch {
            indexRebuildFailed = true
        }

        try? fileManager.removeItem(at: stagingURL)

        return ClipboardBackupImportOutcome(
            plan: prepared.plan,
            indexedCount: indexedCount,
            indexRebuildFailed: indexRebuildFailed,
            appliedSettings: appliedSettings
        )
    }

    // MARK: - Rollback + stale-staging recovery

    /// Restores every journaled file from its pre-image (or deletes it if it
    /// was newly created), reverse of the commit order. Byte-identical tree
    /// by construction. Only acts once the journal reached "mutating".
    static func rollback(journal: ClipboardBackupJournal, stagingURL: URL, archiveRoot: URL) throws {
        guard journal.status == "mutating" else {
            return
        }
        let fileManager = FileManager.default
        let preImagesURL = stagingURL.appendingPathComponent(preImagesDirectoryName, isDirectory: true)

        for relativePath in journal.createdFiles.reversed() {
            guard let url = try? ClipboardArchivePath.containedURL(
                relativePath: relativePath,
                archiveRoot: archiveRoot
            ) else {
                continue
            }
            if fileManager.fileExists(atPath: url.path) {
                try? fileManager.removeItem(at: url)
            }
            removeEmptyParents(of: url, upTo: archiveRoot)
        }
        for relativePath in journal.mutatedFiles.reversed() {
            let preImage = preImagesURL.appendingPathComponent(relativePath)
            guard fileManager.fileExists(atPath: preImage.path),
                  let url = try? ClipboardArchivePath.containedURL(
                    relativePath: relativePath,
                    archiveRoot: archiveRoot
                  ) else {
                continue
            }
            let data = try Data(contentsOf: preImage)
            try ClipboardPrivateFileSystem.createDirectory(
                url.deletingLastPathComponent(),
                archiveRoot: archiveRoot
            )
            try data.write(to: url, options: [.atomic])
            try ClipboardPrivateFileSystem.secureFile(url)
        }
        if let settingsPath = journal.settingsPath {
            let settingsURL = URL(fileURLWithPath: settingsPath)
            if journal.settingsCreated {
                try? fileManager.removeItem(at: settingsURL)
            } else if journal.settingsMutated {
                let preImage = stagingURL.appendingPathComponent(settingsPreImageName)
                if fileManager.fileExists(atPath: preImage.path) {
                    let data = try Data(contentsOf: preImage)
                    try data.write(to: settingsURL, options: [.atomic])
                    try ClipboardPrivateFileSystem.secureFile(settingsURL)
                }
            }
        }
    }

    /// Detects staging directories left behind by a crash. A journal in
    /// "mutating" state is rolled back to the pre-image tree first; then the
    /// staging directory (decrypted plaintext) is deleted. Returns how many
    /// stale directories were cleaned.
    @discardableResult
    public static func recoverStaleStaging(archiveRoot: URL) throws -> Int {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: archiveRoot.path) else {
            return 0
        }
        let items = (try? fileManager.contentsOfDirectory(atPath: archiveRoot.path)) ?? []
        var recovered = 0
        for name in items where name.hasPrefix(stagingPrefix) {
            let stagingURL = archiveRoot.appendingPathComponent(name, isDirectory: true)
            let journalURL = stagingURL.appendingPathComponent(journalFileName)
            if let data = try? Data(contentsOf: journalURL) {
                let decoder = JSONDecoder()
                decoder.dateDecodingStrategy = .iso8601
                if let journal = try? decoder.decode(ClipboardBackupJournal.self, from: data) {
                    try rollback(journal: journal, stagingURL: stagingURL, archiveRoot: archiveRoot)
                }
            }
            try fileManager.removeItem(at: stagingURL)
            recovered += 1
        }
        return recovered
    }

    private static func removeEmptyParents(of url: URL, upTo root: URL) {
        let fileManager = FileManager.default
        let rootPath = root.standardizedFileURL.path
        var current = url.deletingLastPathComponent()
        while current.standardizedFileURL.path.hasPrefix(rootPath + "/") {
            let contents = (try? fileManager.contentsOfDirectory(atPath: current.path)) ?? []
            guard contents.isEmpty else {
                return
            }
            try? fileManager.removeItem(at: current)
            current = current.deletingLastPathComponent()
        }
    }

    // MARK: - Commit primitives

    private func containedArchiveURL(_ relativePath: String) throws -> URL {
        guard let url = try? ClipboardArchivePath.containedURL(
            relativePath: relativePath,
            archiveRoot: archiveRoot
        ) else {
            throw ClipboardBackupError.entryPathRejected(relativePath)
        }
        return url
    }

    private func writeJournal(_ journal: ClipboardBackupJournal, stagingURL: URL) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(journal)
        let url = stagingURL.appendingPathComponent(Self.journalFileName)
        try data.write(to: url, options: [.atomic])
        try ClipboardPrivateFileSystem.secureFile(url)
    }

    private func copyPreImage(relativePath: String, preImagesURL: URL) throws {
        let source = try containedArchiveURL(relativePath)
        let target = preImagesURL.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(
            at: target.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: NSNumber(value: Int16(0o700))]
        )
        if FileManager.default.fileExists(atPath: target.path) {
            try FileManager.default.removeItem(at: target)
        }
        try FileManager.default.copyItem(at: source, to: target)
    }

    /// Re-copies the current bytes right before the first mutation of a
    /// file, so appends made by a concurrent capture since the preview are
    /// preserved by any rollback.
    private func refreshPreImage(relativePath: String, preImagesURL: URL) throws {
        let source = try containedArchiveURL(relativePath)
        guard FileManager.default.fileExists(atPath: source.path) else {
            return
        }
        try copyPreImage(relativePath: relativePath, preImagesURL: preImagesURL)
    }

    private func copyStagedFile(_ relativePath: String, stagingURL: URL, preImagesURL: URL) throws {
        let source = stagingURL.appendingPathComponent(relativePath)
        let target = try containedArchiveURL(relativePath)
        if FileManager.default.fileExists(atPath: target.path) {
            try refreshPreImage(relativePath: relativePath, preImagesURL: preImagesURL)
            try FileManager.default.removeItem(at: target)
        }
        try ClipboardPrivateFileSystem.createDirectory(
            target.deletingLastPathComponent(),
            archiveRoot: archiveRoot
        )
        try FileManager.default.copyItem(at: source, to: target)
        try ClipboardPrivateFileSystem.secureFile(target)
    }

    private func appendLines(_ lines: [Data], toRelativePath relativePath: String) throws {
        let url = try containedArchiveURL(relativePath)
        try ClipboardPrivateFileSystem.createDirectory(
            url.deletingLastPathComponent(),
            archiveRoot: archiveRoot
        )
        var payload = Data()
        for line in lines {
            payload.append(line)
            payload.append(0x0A)
        }
        if FileManager.default.fileExists(atPath: url.path) {
            let handle = try FileHandle(forWritingTo: url)
            try handle.seekToEnd()
            try handle.write(contentsOf: payload)
            try handle.close()
        } else {
            try payload.write(to: url, options: [.atomic])
        }
        try ClipboardPrivateFileSystem.secureFile(url)
    }

    /// Reads the CURRENT file (which may have grown since the preview),
    /// appends the planned lines, and atomically replaces — the "event day
    /// files (atomic replace each)" step.
    private func appendLinesAtomically(_ lines: [Data], toRelativePath relativePath: String) throws {
        let url = try containedArchiveURL(relativePath)
        var payload = (try? Data(contentsOf: url)) ?? Data()
        if !payload.isEmpty, payload.last != 0x0A {
            payload.append(0x0A)
        }
        for line in lines {
            payload.append(line)
            payload.append(0x0A)
        }
        try writeFileAtomically(payload, toRelativePath: relativePath)
    }

    private func writeFileAtomically(_ data: Data, toRelativePath relativePath: String) throws {
        let url = try containedArchiveURL(relativePath)
        try ClipboardPrivateFileSystem.createDirectory(
            url.deletingLastPathComponent(),
            archiveRoot: archiveRoot
        )
        let temporaryURL = url.deletingLastPathComponent()
            .appendingPathComponent(".import-tmp-\(UUID().uuidString)")
        try data.write(to: temporaryURL, options: [.atomic])
        try ClipboardPrivateFileSystem.secureFile(temporaryURL)
        _ = try FileManager.default.replaceItemAt(url, withItemAt: temporaryURL)
        try ClipboardPrivateFileSystem.secureFile(url)
    }

    static func decodeSettings(_ data: Data) -> ClipboardSettings? {
        let isoDecoder = JSONDecoder()
        isoDecoder.dateDecodingStrategy = .iso8601
        if let settings = try? isoDecoder.decode(ClipboardSettings.self, from: data) {
            return settings
        }
        return try? JSONDecoder().decode(ClipboardSettings.self, from: data)
    }

    /// UTC day-file path for a capture date, matching the writer's layout
    /// exactly (raw/YYYY/MM/YYYY-MM-DD_clipboard-events.ndjson).
    static func dayFileRelativePath(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        let day = formatter.string(from: date)
        let year = String(day.prefix(4))
        let month = String(day.dropFirst(5).prefix(2))
        return "raw/\(year)/\(month)/\(day)_clipboard-events.ndjson"
    }
}
