import ClipboardArchiveCore
import Darwin
import Foundation

// Slice 8 CLI: `backup create|inspect|restore`. Passphrases come from the
// terminal via readpassphrase(3) (echo off) or from stdin with
// --passphrase-stdin (tests/automation). NEVER from argv or the
// environment, and never printed or logged. Buffers are zeroized
// best-effort after use.

enum BackupCLIError: Error, CustomStringConvertible {
    case usage(String)
    case passphraseReadFailed
    case passphraseMismatch
    case passphraseTooShort

    var description: String {
        switch self {
        case let .usage(message):
            return message
        case .passphraseReadFailed:
            return "could not read passphrase (no terminal? use --passphrase-stdin)"
        case .passphraseMismatch:
            return "passphrases did not match"
        case .passphraseTooShort:
            return "passphrase must be at least 8 characters"
        }
    }
}

enum BackupPassphraseReader {
    /// One line from stdin, newline stripped. For tests and scripts only.
    static func fromStandardInput() throws -> Data {
        guard let line = readLine(strippingNewline: true) else {
            throw BackupCLIError.passphraseReadFailed
        }
        return Data(line.utf8)
    }

    /// readpassphrase(3): reads from the controlling terminal with echo
    /// off. The intermediate C buffer is zeroized before returning.
    static func fromTerminal(prompt: String) throws -> Data {
        var buffer = [CChar](repeating: 0, count: 1024)
        defer { memset_s(&buffer, buffer.count, 0, buffer.count) }
        guard readpassphrase(prompt, &buffer, buffer.count, 0) != nil else {
            throw BackupCLIError.passphraseReadFailed
        }
        return buffer.withUnsafeBufferPointer { pointer in
            Data(bytes: pointer.baseAddress!, count: strlen(pointer.baseAddress!))
        }
    }

    static func read(useStandardInput: Bool, prompt: String, confirm: Bool) throws -> Data {
        if useStandardInput {
            var passphrase = try fromStandardInput()
            if confirm, passphrase.count < ClipboardBackupFormat.passphraseMinimumLength {
                ClipboardBackupPassphrase.zero(&passphrase)
                throw BackupCLIError.passphraseTooShort
            }
            return passphrase
        }
        var passphrase = try fromTerminal(prompt: prompt)
        if confirm {
            if passphrase.count < ClipboardBackupFormat.passphraseMinimumLength {
                ClipboardBackupPassphrase.zero(&passphrase)
                throw BackupCLIError.passphraseTooShort
            }
            var second = try fromTerminal(prompt: "Repeat passphrase: ")
            defer { ClipboardBackupPassphrase.zero(&second) }
            guard passphrase == second else {
                ClipboardBackupPassphrase.zero(&passphrase)
                throw BackupCLIError.passphraseMismatch
            }
        }
        return passphrase
    }
}

func runBackupCommand(options: CLIOptions) throws {
    guard let subcommand = options.positional.first else {
        throw BackupCLIError.usage(
            "backup requires a subcommand: create | inspect | restore"
        )
    }
    guard options.positional.count >= 2 else {
        throw BackupCLIError.usage("backup \(subcommand) requires a file path")
    }
    let fileURL = URL(fileURLWithPath: options.positional[1])
    let jsonEncoder = JSONEncoder()
    jsonEncoder.dateEncodingStrategy = .iso8601
    jsonEncoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]

    switch subcommand {
    case "create":
        // Stale staging from an interrupted restore is rolled back at every
        // backup entry point.
        _ = try ClipboardBackupImporter.recoverStaleStaging(archiveRoot: options.archiveRoot)
        var passphrase = try BackupPassphraseReader.read(
            useStandardInput: options.passphraseStdin,
            prompt: "Backup passphrase (min 8 characters): ",
            confirm: true
        )
        defer { ClipboardBackupPassphrase.zero(&passphrase) }
        let exporter = ClipboardBackupExporter(archiveRoot: options.archiveRoot)
        let result = try exporter.export(
            to: fileURL,
            passphrase: passphrase,
            includeSettings: options.includeSettings
        )
        print("backup created: \(result.outputURL.path)")
        print("backup_id: \(result.manifest.backupID)")
        print("container_bytes: \(result.containerBytes)")
        print("pbkdf2_iterations: \(result.iterations)")
        print("stored_events: \(result.manifest.counts.storedEvents)")
        print("blocked_events: \(result.manifest.counts.blockedEvents)")
        print("tombstones: \(result.manifest.counts.tombstoneEvents)")
        print("ledger_records: \(result.manifest.counts.ledgerRecords)")
        print("body_files: \(result.manifest.counts.bodyFiles)")
        print("annotations: \(result.manifest.counts.annotationRecords)")
        print("collections: \(result.manifest.counts.collections)")
        print("includes_settings: \(result.manifest.includesSettings)")
        if !result.manifest.filesNotIncluded.isEmpty {
            print("not_included (\(result.manifest.filesNotIncluded.count)):")
            for name in result.manifest.filesNotIncluded {
                print("  \(name)")
            }
        }

    case "inspect":
        var passphrase = try BackupPassphraseReader.read(
            useStandardInput: options.passphraseStdin,
            prompt: "Backup passphrase: ",
            confirm: false
        )
        defer { ClipboardBackupPassphrase.zero(&passphrase) }
        let inspection = try ClipboardBackupInspector.inspect(fileURL: fileURL, passphrase: passphrase)
        if options.json {
            struct InspectOutput: Encodable {
                var manifest: ClipboardBackupManifest
                var iterations: Int
                var containerBytes: Int64
                var framingIntact: Bool
            }
            let output = InspectOutput(
                manifest: inspection.manifest,
                iterations: inspection.iterations,
                containerBytes: inspection.containerBytes,
                framingIntact: inspection.framingIntact
            )
            print(String(data: try jsonEncoder.encode(output), encoding: .utf8) ?? "{}")
        } else {
            let manifest = inspection.manifest
            let formatter = ISO8601DateFormatter()
            print("backup_id: \(manifest.backupID)")
            print("created_at: \(formatter.string(from: manifest.createdAt))")
            print("app_version: \(manifest.appVersion)")
            print("pbkdf2_iterations: \(inspection.iterations)")
            print("container_bytes: \(inspection.containerBytes)")
            print("total_plaintext_bytes: \(manifest.totalPlaintextBytes)")
            print("entries: \(manifest.entries.count)")
            print("stored_events: \(manifest.counts.storedEvents)")
            print("blocked_events: \(manifest.counts.blockedEvents)")
            print("tombstones: \(manifest.counts.tombstoneEvents)")
            print("ledger_records: \(manifest.counts.ledgerRecords)")
            print("body_files: \(manifest.counts.bodyFiles)")
            print("annotations: \(manifest.counts.annotationRecords)")
            print("collections: \(manifest.counts.collections)")
            print("includes_settings: \(manifest.includesSettings)")
            if let earliest = manifest.earliestCapturedAt {
                print("earliest_captured_at: \(formatter.string(from: earliest))")
            }
            if let latest = manifest.latestCapturedAt {
                print("latest_captured_at: \(formatter.string(from: latest))")
            }
            if !manifest.filesNotIncluded.isEmpty {
                print("not_included (\(manifest.filesNotIncluded.count)):")
                for name in manifest.filesNotIncluded {
                    print("  \(name)")
                }
            }
        }

    case "restore":
        var passphrase = try BackupPassphraseReader.read(
            useStandardInput: options.passphraseStdin,
            prompt: "Backup passphrase: ",
            confirm: false
        )
        defer { ClipboardBackupPassphrase.zero(&passphrase) }
        let importer = ClipboardBackupImporter(
            archiveRoot: options.archiveRoot,
            indexURL: options.indexPath
        )
        let importOptions = ClipboardBackupImportOptions(
            merge: options.merge,
            applySettings: options.applySettings
        )
        let outcome = try importer.run(
            backupFileURL: fileURL,
            passphrase: passphrase,
            options: importOptions,
            dryRun: options.dryRun
        )
        if options.json {
            struct RestoreOutput: Encodable {
                var dryRun: Bool
                var plan: ClipboardBackupImportPlan
                var indexedCount: Int?
                var indexRebuildFailed: Bool
                var appliedSettings: Bool
            }
            let output = RestoreOutput(
                dryRun: options.dryRun,
                plan: outcome.plan,
                indexedCount: outcome.indexedCount,
                indexRebuildFailed: outcome.indexRebuildFailed,
                appliedSettings: outcome.appliedSettings
            )
            print(String(data: try jsonEncoder.encode(output), encoding: .utf8) ?? "{}")
        } else {
            let plan = outcome.plan
            print(options.dryRun ? "restore dry run (no changes made)" : "restore complete")
            print("mode: \(plan.mode)")
            print("backup_id: \(plan.backupID)")
            print("new_events: \(plan.newEvents)")
            print("new_tombstones: \(plan.newTombstones)")
            print("skipped_existing: \(plan.skippedExistingEvents)")
            print("skipped_deleted_here: \(plan.skippedDeletedHere)")
            print("unreadable_lines: \(plan.unreadableLines)")
            print("ledger_records_added: \(plan.ledgerRecordsToAdd)")
            print("locally_live_newly_suppressed: \(plan.locallyLiveNewlySuppressed)")
            print("blocked_appended: \(plan.blockedLinesToAppend)")
            print("blocked_skipped_identical: \(plan.blockedLinesSkippedIdentical)")
            print("bodies_added: \(plan.bodiesToAdd)")
            print("bodies_skipped_identical: \(plan.bodiesSkippedIdentical)")
            print("bodies_skipped_deleted_here: \(plan.bodiesSkippedDeletedHere)")
            print("manifest_files_added: \(plan.manifestFilesToAdd)")
            print("manifest_files_skipped: \(plan.manifestFilesSkipped)")
            print("annotations_added: \(plan.annotationsAdded)")
            print("annotations_merged: \(plan.annotationsMerged)")
            print("annotation_conflicts_local_wins: \(plan.annotationConflictsLocalWins)")
            print("collections_added: \(plan.collectionsAdded)")
            print("collections_merged_by_id: \(plan.collectionsMergedByID)")
            print("collections_renamed: \(plan.collectionsRenamed)")
            print("applied_settings: \(outcome.appliedSettings)")
            if !options.dryRun {
                if outcome.indexRebuildFailed {
                    print("index: rebuild FAILED — run repair-index (archive data is intact)")
                } else if let count = outcome.indexedCount {
                    print("index: rebuilt (\(count) items)")
                }
            }
        }

    default:
        throw BackupCLIError.usage("unknown backup subcommand: \(subcommand)")
    }
}
