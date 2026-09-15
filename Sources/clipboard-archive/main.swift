import ClipboardArchiveCore
import AppKit
import Foundation

struct CLIOptions {
    var command: String
    var positional: [String]
    var archiveRoot: URL
    var indexPath: URL
    /// Where those two paths came from, for the surfaces that report it.
    var storeResolution: ClipboardStoreResolution
    var intervalSeconds: TimeInterval
    var durationSeconds: TimeInterval?
    var inlineLimitBytes: Int
    var limit: Int
    var since: Date?
    var until: Date?
    var verbose: Bool
    var json: Bool
    var dryRun: Bool
    var includePinned: Bool
    var bundleID: String?
    var appName: String?
    var contentType: String?
    var sensitivity: String?
    // Slice 8 backup flags.
    var includeSettings: Bool
    var passphraseStdin: Bool
    var merge: Bool
    var applySettings: Bool
    /// `logs` flags.
    var tail: Int
    var errorsOnly: Bool
    /// This command's own operational sink, resolved with the stores.
    var operationalLog: ClipboardOperationalLog

    static func parse(_ arguments: [String]) throws -> CLIOptions {
        var args = Array(arguments.dropFirst())
        let command = args.first ?? "help"
        if !args.isEmpty {
            args.removeFirst()
        }

        var positional: [String] = []
        var archiveRootOverride: URL?
        var indexPathOverride: URL?
        var intervalSeconds: TimeInterval = 1.0
        var durationSeconds: TimeInterval?
        var inlineLimitBytes = 64 * 1024
        var limit = 25
        var since: Date?
        var until: Date?
        var verbose = false
        var json = false
        var dryRun = false
        var includePinned = false
        var bundleID: String?
        var appName: String?
        var contentType: String?
        var sensitivity: String?
        var includeSettings = false
        var passphraseStdin = false
        var merge = false
        var applySettings = false
        var tail = 50
        var errorsOnly = false

        var index = 0
        while index < args.count {
            let arg = args[index]
            switch arg {
            case "--archive-root":
                index += 1
                guard index < args.count else { throw CLIError.missingValue("--archive-root") }
                archiveRootOverride = URL(fileURLWithPath: args[index])
            case "--index-path":
                index += 1
                guard index < args.count else { throw CLIError.missingValue("--index-path") }
                indexPathOverride = URL(fileURLWithPath: args[index])
            case "--interval":
                index += 1
                guard index < args.count, let value = TimeInterval(args[index]), value > 0 else {
                    throw CLIError.invalidValue("--interval")
                }
                intervalSeconds = value
            case "--duration":
                index += 1
                guard index < args.count, let value = TimeInterval(args[index]), value > 0 else {
                    throw CLIError.invalidValue("--duration")
                }
                durationSeconds = value
            case "--inline-limit-bytes":
                index += 1
                guard index < args.count, let value = Int(args[index]), value >= 0 else {
                    throw CLIError.invalidValue("--inline-limit-bytes")
                }
                inlineLimitBytes = value
            case "--limit":
                index += 1
                guard index < args.count, let value = Int(args[index]), value > 0 else {
                    throw CLIError.invalidValue("--limit")
                }
                limit = value
            case "--since":
                index += 1
                guard index < args.count, let value = Self.parseDate(args[index]) else {
                    throw CLIError.invalidValue("--since")
                }
                since = value
            case "--until":
                index += 1
                guard index < args.count, let value = Self.parseDate(args[index]) else {
                    throw CLIError.invalidValue("--until")
                }
                until = value
            case "--bundle-id":
                index += 1
                guard index < args.count, !args[index].isEmpty else {
                    throw CLIError.missingValue("--bundle-id")
                }
                bundleID = args[index]
            case "--app":
                index += 1
                guard index < args.count, !args[index].isEmpty else {
                    throw CLIError.missingValue("--app")
                }
                appName = args[index]
            case "--type":
                index += 1
                guard index < args.count, !args[index].isEmpty else {
                    throw CLIError.missingValue("--type")
                }
                contentType = args[index]
            case "--sensitivity":
                index += 1
                guard index < args.count,
                      ClipboardBulkCriteria.Sensitivity(rawValue: args[index]) != nil else {
                    throw CLIError.invalidValue("--sensitivity (any-flagged | manual-restricted)")
                }
                sensitivity = args[index]
            case "--verbose":
                verbose = true
            case "--json":
                json = true
            case "--dry-run":
                dryRun = true
            case "--include-pinned":
                includePinned = true
            case "--include-settings":
                includeSettings = true
            case "--passphrase-stdin":
                passphraseStdin = true
            case "--merge":
                merge = true
            case "--apply-settings":
                applySettings = true
            case "--tail":
                index += 1
                guard index < args.count, let value = Int(args[index]), value > 0 else {
                    throw CLIError.invalidValue("--tail")
                }
                tail = value
            case "--errors":
                errorsOnly = true
            default:
                if arg.hasPrefix("--") {
                    throw CLIError.unknownArgument(arg)
                }
                positional.append(arg)
            }
            index += 1
        }

        // One resolver for this CLI and the app: explicit argument, then
        // environment variable, then the pointer the running app published,
        // then the per-user default — decided for each path on its own.
        let resolution = ClipboardStoreLocator.resolve(
            overrides: ClipboardStoreOverrides(
                archiveRoot: archiveRootOverride,
                indexPath: indexPathOverride
            )
        )

        return CLIOptions(
            command: command,
            positional: positional,
            archiveRoot: resolution.archiveRoot,
            indexPath: resolution.indexPath,
            storeResolution: resolution,
            intervalSeconds: intervalSeconds,
            durationSeconds: durationSeconds,
            inlineLimitBytes: inlineLimitBytes,
            limit: limit,
            since: since,
            until: until,
            verbose: verbose,
            json: json,
            dryRun: dryRun,
            includePinned: includePinned,
            bundleID: bundleID,
            appName: appName,
            contentType: contentType,
            sensitivity: sensitivity,
            includeSettings: includeSettings,
            passphraseStdin: passphraseStdin,
            merge: merge,
            applySettings: applySettings,
            tail: tail,
            errorsOnly: errorsOnly,
            operationalLog: ClipboardOperationalLog(directory: resolution.logDirectory)
        )
    }

    static func parseDate(_ value: String) -> Date? {
        if let date = ISO8601DateFormatter().date(from: value) {
            return date
        }
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone.current
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.date(from: value)
    }
}

enum CLIError: Error, CustomStringConvertible {
    case missingValue(String)
    case invalidValue(String)
    case unknownArgument(String)
    case unreadableHealthReport

    var description: String {
        switch self {
        case .unreadableHealthReport:
            return "could not render the health report as JSON"
        case let .missingValue(argument):
            return "missing value for \(argument)"
        case let .invalidValue(argument):
            return "invalid value for \(argument)"
        case let .unknownArgument(argument):
            return "unknown argument \(argument)"
        }
    }
}

struct PasteboardMonitor {
    var pasteboard: NSPasteboard
    var ingestor: ClipboardIngestor
    var intervalSeconds: TimeInterval
    var durationSeconds: TimeInterval?
    var verbose: Bool

    func run() throws {
        var lastChangeCount = pasteboard.changeCount
        var lastContentHash: String?
        let startedAt = Date()

        print("monitor started")
        print("archive root: \(ingestor.archiveWriter.archiveRoot.path)")
        if let durationSeconds {
            print("duration: \(durationSeconds)s")
        } else {
            print("duration: until interrupted")
        }

        while true {
            if let durationSeconds, Date().timeIntervalSince(startedAt) >= durationSeconds {
                print("monitor stopped: duration reached")
                return
            }

            let changeCount = pasteboard.changeCount
            if changeCount != lastChangeCount {
                lastChangeCount = changeCount
                if let capture = readTextCapture() {
                    let contentHash = String(capture.content.hashValue)
                    if contentHash != lastContentHash {
                        lastContentHash = contentHash
                        try ingest(capture)
                    }
                } else if verbose {
                    print("ignored non-text clipboard change")
                }
            }

            Thread.sleep(forTimeInterval: intervalSeconds)
        }
    }

    private func readTextCapture() -> ClipboardCapture? {
        guard let content = pasteboard.string(forType: .string), !content.isEmpty else {
            return nil
        }

        let runningApplication = NSWorkspace.shared.frontmostApplication
        let sourceApp = ClipboardSourceApp(
            name: runningApplication?.localizedName ?? "Unknown",
            bundleIdentifier: runningApplication?.bundleIdentifier
        )
        let types = pasteboard.types?.map(\.rawValue) ?? []

        return ClipboardCapture(
            capturedAt: Date(),
            content: content,
            sourceApp: sourceApp,
            pasteboardTypes: types
        )
    }

    private func ingest(_ capture: ClipboardCapture) throws {
        let result = try ingestor.ingest(capture)
        switch result {
        case let .stored(event, indexUpdate):
            print("stored \(event.id) \(event.byteCount)b \(event.sourceApp.name)")
            if indexUpdate == .failed {
                FileHandle.standardError.write(
                    Data("warning: archive stored; incremental index update failed\n".utf8)
                )
            }
        case let .blocked(reason):
            print("blocked \(reason)")
        }
    }
}

/// One operational row per invocation, with the verb and the exit code, so
/// a scheduled or scripted command that started failing is visible without
/// anyone having captured its output. Best effort by design: a command
/// interrupted mid-run (a `monitor` stopped with Ctrl-C) leaves no row.
func recordCLICommand(_ log: ClipboardOperationalLog, verb: ClipboardOperationalLog.Verb, exitCode: Int) {
    log.record(
        .cliCommand,
        level: exitCode == 0 ? .info : .error,
        count: exitCode,
        verb: verb
    )
}

let cliVerb = ClipboardOperationalLog.Verb(
    command: CommandLine.arguments.dropFirst().first ?? "help"
)

do {
    let options = try CLIOptions.parse(CommandLine.arguments)

    switch options.command {
case "self-test":
    let root = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("clipboard-archive-self-test-\(UUID().uuidString)")
    let writer = ClipboardArchiveWriter(archiveRoot: root, inlineContentLimitBytes: 32)
    let capture = ClipboardCapture(
        capturedAt: Date(timeIntervalSince1970: 1_800_000_000),
        content: "Clipboard Archive local self-test note",
        sourceApp: ClipboardSourceApp(name: "Safari", bundleIdentifier: "com.apple.Safari"),
        pasteboardTypes: ["public.utf8-plain-text"]
    )
    _ = try writer.archiveAllowedCapture(capture)
    print("self-test ok: \(root.path)")

case "monitor":
    let writer = ClipboardArchiveWriter(
        archiveRoot: options.archiveRoot,
        inlineContentLimitBytes: options.inlineLimitBytes
    )
    let monitor = PasteboardMonitor(
        pasteboard: .general,
        ingestor: ClipboardIngestor(
            archiveWriter: writer,
            derivedIndex: ClipboardDerivedIndex(
                archiveRoot: options.archiveRoot,
                indexURL: options.indexPath,
                operationalLog: options.operationalLog
            ),
            operationalLog: options.operationalLog
        ),
        intervalSeconds: options.intervalSeconds,
        durationSeconds: options.durationSeconds,
        verbose: options.verbose
    )
    try monitor.run()

case "search":
    guard let query = options.positional.first else {
        throw CLIError.missingValue("search query")
    }
    let searcher = ClipboardArchiveSearcher(archiveRoot: options.archiveRoot)
    let results = try searcher.search(ClipboardSearchOptions(
        query: query,
        since: options.since,
        until: options.until,
        limit: options.limit
    ))
    if results.isEmpty {
        print("no matches")
    } else {
        for result in results {
            let event = result.event
            print("\(ISO8601DateFormatter().string(from: event.capturedAt)) \(event.id) \(event.sourceApp.name) \(result.matchedInBody ? "body" : "meta")")
            print(result.snippet)
            print("")
        }
    }

case "redact":
    guard let id = options.positional.first else {
        throw CLIError.missingValue("clipboard event id")
    }
    let result = try ClipboardArchiveRedactor(archiveRoot: options.archiveRoot, indexURL: options.indexPath).redact(eventID: id)
    print("redacted \(result.eventID)")
    print("event file: \(result.redactedEventFile)")
    if let deletedBodyFile = result.deletedBodyFile {
        print("deleted body: \(deletedBodyFile)")
    }
    if result.skippedUnsafeBodyPath {
        print("warning: unsafe body path was removed from the event without touching the referenced file")
    }

case "prune":
    guard let before = options.until ?? options.since ?? options.positional.first.flatMap(CLIOptions.parseDate) else {
        throw CLIError.missingValue("prune cutoff date; use --until YYYY-MM-DD")
    }
    let result = try ClipboardArchivePruner(archiveRoot: options.archiveRoot, indexURL: options.indexPath)
        .pruneContent(before: before, dryRun: options.dryRun, includePinned: options.includePinned)
    if options.json {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        print(String(data: try encoder.encode(result), encoding: .utf8) ?? "{}")
    } else {
        print(options.dryRun ? "prune dry run" : "prune complete")
        print("cutoff: \(ISO8601DateFormatter().string(from: before))")
        print("scanned: \(result.scannedEvents)")
        print("pruned: \(result.prunedEvents)")
        print("deleted_body_files: \(result.deletedBodyFiles)")
        print("changed_files: \(result.changedFiles)")
        print("exempt_pinned: \(result.exemptedPinnedEvents)")
    }

case "bulk":
    // Truthful preview first: bulk deletion is not undoable, so the CLI
    // requires --dry-run for the preview and prints the SAME numbers the
    // real run reports (one shared engine path).
    let criteria = ClipboardBulkCriteria(
        since: options.since,
        until: options.until,
        bundleID: options.bundleID,
        sourceAppName: options.appName,
        contentType: options.contentType,
        sensitivity: options.sensitivity.flatMap(ClipboardBulkCriteria.Sensitivity.init(rawValue:)),
        includePinned: options.includePinned
    )
    guard !criteria.isEmpty else {
        throw CLIError.missingValue(
            "bulk criteria; pass at least one of --since/--until/--bundle-id/--app/--type/--sensitivity"
        )
    }
    let engine = ClipboardBulkEngine(archiveRoot: options.archiveRoot, indexURL: options.indexPath)
    let result = options.dryRun
        ? try engine.preview(criteria)
        : try engine.execute(criteria)
    if options.json {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        print(String(data: try encoder.encode(result), encoding: .utf8) ?? "{}")
    } else {
        print(options.dryRun ? "bulk dry run (no changes made)" : "bulk delete complete (not undoable)")
        print("reason: \(result.reason)")
        print("matched: \(result.matchedEvents)")
        print("reclaimed_bytes: \(result.reclaimedBytes)")
        print("deleted_body_files: \(result.deletedBodyFiles)")
        print("changed_files: \(result.changedFiles)")
        print("exempt_pinned: \(result.exemptedPinnedEvents)")
        print("removed_annotation_hashes: \(result.removedAnnotationHashes)")
    }

case "sweep-expired":
    let sweeper = ClipboardExpirySweeper(archiveRoot: options.archiveRoot, indexURL: options.indexPath)
    if let nextDue = sweeper.nextDue() {
        print("next_due: \(ISO8601DateFormatter().string(from: nextDue))")
    } else {
        print("next_due: none")
    }
    let result = try sweeper.sweepIfDue()
    if options.json {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        print(String(data: try encoder.encode(result), encoding: .utf8) ?? "{}")
    } else {
        print("swept_hashes: \(result.sweptContentHashes)")
        print("deleted_events: \(result.deletedEvents)")
        print("reclaimed_bytes: \(result.reclaimedBytes)")
    }

case "repair-index":
    let index = ClipboardDerivedIndex(
        archiveRoot: options.archiveRoot,
        indexURL: options.indexPath,
        operationalLog: options.operationalLog
    )
    let count = try index.rebuild()
    print("index rebuilt: \(count) item(s)")
    print("index path: \(index.indexURL.path)")

case "index-search":
    guard let query = options.positional.first else {
        throw CLIError.missingValue("search query")
    }
    let output = try ClipboardDerivedIndex(archiveRoot: options.archiveRoot, indexURL: options.indexPath).search(query, limit: options.limit)
    print(output.isEmpty ? "no matches" : output)

case "stores":
    let resolution = options.storeResolution
    let alternate = ClipboardStoreLocator.alternateIndexReport(for: resolution)
    if options.json {
        var object: [String: Any] = [
            "schema": 1,
            "archive": ["path": resolution.archiveRoot.path, "origin": resolution.archiveOrigin.rawValue],
            "index": ["path": resolution.indexPath.path, "origin": resolution.indexOrigin.rawValue],
            "settings": ["path": resolution.settingsURL.path],
            "lock": ["path": resolution.lockURL.path],
            "pointer": ["path": resolution.pointerURL.path, "status": resolution.pointerStatus.rawValue]
        ]
        if let alternate {
            // An unreadable database reports null rather than dropping the
            // key, so the JSON shape matches the text output's "unreadable".
            let report: [String: Any] = [
                "path": alternate.path,
                "bytes": alternate.bytes,
                "rows": alternate.rowCount.map { $0 as Any } ?? NSNull(),
                "index_user_version": alternate.userVersion.map { $0 as Any } ?? NSNull()
            ]
            object["alternate_index"] = report
        }
        let data = try JSONSerialization.data(
            withJSONObject: object,
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        )
        print(String(data: data, encoding: .utf8) ?? "{}")
    } else {
        print("Clipboard Archive stores")
        print("archive: \(resolution.archiveRoot.path) (\(resolution.archiveOrigin.rawValue))")
        print("index: \(resolution.indexPath.path) (\(resolution.indexOrigin.rawValue))")
        print("settings: \(resolution.settingsURL.path)")
        print("lock: \(resolution.lockURL.path)")
        print("pointer: \(resolution.pointerURL.path) (\(resolution.pointerStatus.rawValue))")
        if let alternate {
            print("alternate_index: \(alternate.path)")
            print("alternate_index_bytes: \(alternate.bytes)")
            print("alternate_index_rows: \(alternate.rowCount.map(String.init) ?? "unreadable")")
            print("alternate_index_user_version: \(alternate.userVersion.map(String.init) ?? "unreadable")")
        } else {
            print("alternate_index: none")
        }
    }

case "health":
    let reporter = ClipboardArchiveHealthReporter(archiveRoot: options.archiveRoot, indexURL: options.indexPath)
    let health = try reporter.health()
    let resolution = options.storeResolution
    let alternateIndexBytes = ClipboardStoreLocator.alternateIndexReport(for: resolution)?.bytes ?? 0
    if options.json {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        // The resolution facts are additive: the reporter's own fields are
        // encoded unchanged, then the four store-resolution keys are added.
        guard var object = try JSONSerialization.jsonObject(
            with: try encoder.encode(health)
        ) as? [String: Any] else {
            throw CLIError.unreadableHealthReport
        }
        object["archive_root_source"] = resolution.archiveOrigin.rawValue
        object["index_source"] = resolution.indexOrigin.rawValue
        object["pointer_status"] = resolution.pointerStatus.rawValue
        object["alternate_index_bytes"] = alternateIndexBytes
        let data = try JSONSerialization.data(
            withJSONObject: object,
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        )
        print(String(data: data, encoding: .utf8) ?? "{}")
    } else {
        print("Clipboard Archive health")
        print("archive: \(health.archiveRoot)")
        print("stored: \(health.storedEvents)")
        print("blocked: \(health.blockedEvents)")
        print("deleted: \(health.deletedEvents)")
        print("today: \(health.todayStoredEvents)")
        print("last_7_days: \(health.lastSevenDaysStoredEvents)")
        print("large_bodies: \(health.largeBodyFiles)")
        print("missing_bodies: \(health.missingBodyFiles)")
        print("unsafe_body_paths: \(health.unsafeBodyPaths)")
        print("insecure_files: \(health.insecureFiles)")
        print("invalid_json: \(health.invalidJSONLines)")
        print("archive_bytes: \(health.archiveBytes)")
        print("index_bytes: \(health.indexBytes)")
        print("index_stale: \(health.indexIsStale)")
        print("body_file_bytes: \(health.bodyFileBytes)")
        print("event_files: \(health.eventFileCount)")
        print("restricted_events: \(health.restrictedEvents)")
        print("pinned_items: \(health.pinnedItems)")
        print("tagged_items: \(health.taggedItems)")
        print("expiring_items: \(health.expiringItems)")
        print("index_user_version: \(health.indexUserVersion.map(String.init) ?? "none")")
        print("annotations_bytes: \(health.annotationsBytes)")
        print("rich_content_events: \(health.richContentEvents)")
        print("orphaned_rich_bodies: \(health.orphanedRichBodyFiles)")
        print("archive_root_source: \(resolution.archiveOrigin.rawValue)")
        print("index_source: \(resolution.indexOrigin.rawValue)")
        print("pointer_status: \(resolution.pointerStatus.rawValue)")
        print("alternate_index_bytes: \(alternateIndexBytes)")
        if let oldest = health.oldestCapturedAt {
            print("oldest_captured_at: \(ISO8601DateFormatter().string(from: oldest))")
        }
        if let latest = health.latestCapturedAt {
            print("latest_captured_at: \(ISO8601DateFormatter().string(from: latest))")
        }
    }

case "backup":
    try runBackupCommand(options: options)

case "logs":
    let entries = options.operationalLog.read(
        limit: options.tail,
        errorsOnly: options.errorsOnly,
        since: options.since
    )
    if options.json {
        print("[" + entries.map { "  " + $0.line }.joined(separator: ",\n") + "]")
    } else if entries.isEmpty {
        print("no operational rows")
    } else {
        for entry in entries {
            print(entry.textDescription)
        }
    }

case "write-manifest":
    let url = try ClipboardArchiveHealthReporter(archiveRoot: options.archiveRoot).writeDailyManifest()
    print("manifest written: \(url.path)")

default:
    print("""
    Clipboard Archive

    Commands:
      self-test    Write a sample archive event to a temporary directory.
      monitor      Manually poll NSPasteboard and archive accepted text changes.
      search QUERY Search the local archive.
      redact ID    Redact archived content for one clipboard event.
      prune        Redact stored content before a cutoff date.
      bulk         Bulk-delete by date/app/type/sensitivity criteria.
                   Preview with --dry-run first; execution is not undoable.
      sweep-expired Delete clips whose sensitivity expiry has passed.
      repair-index Rebuild the derived SQLite FTS search index.
      index-search QUERY Search the derived SQLite FTS index.
      health       Report archive/index health.
      logs         Print the operational log (launch, heartbeat, capture
                   failures, rebuilds, prunes). Options: --tail N (default
                   50), --errors, --since, --json.
      stores       Report which archive, index, settings, lock and pointer
                   file this command resolved, and where each came from.
      write-manifest Write today's daily manifest.
      backup create FILE   Write an encrypted backup (.clipbak) of the archive.
                           Options: --include-settings, --passphrase-stdin.
      backup inspect FILE  Decrypt and show a backup's manifest (needs the
                           passphrase). Options: --json, --passphrase-stdin.
      backup restore FILE  Restore a backup. Without --merge the archive must
                           be empty; --merge imports missing items (local
                           deletions always win). Options: --merge, --dry-run,
                           --apply-settings, --json, --passphrase-stdin.

    Monitor options:
      --duration SECONDS            Stop after this many seconds.
      --interval SECONDS            Polling interval. Default: 1.
      --archive-root PATH           Archive location. Resolved in order: this argument,
                                    then CLIPBOARD_ARCHIVE_ARCHIVE_ROOT, then the pointer
                                    the running app published, then
                                    ~/Library/Application Support/ClipboardArchive/Archive/clipboard-history.
      --index-path PATH             Derived search index location used by monitor, redact,
                                    prune, repair-index, index-search, and health. Resolved in
                                    order: this argument, then CLIPBOARD_ARCHIVE_INDEX_PATH,
                                    then the pointer the running app published, then
                                    ~/Library/Application Support/ClipboardArchive/Indexes/clipboard-search.sqlite.
                                    Run `stores` to see which one won.
      --inline-limit-bytes BYTES    Default: 65536. Larger content uses body files.
      --limit N                     Search result limit. Default: 25.
      --since YYYY-MM-DD            Search lower date bound.
      --until YYYY-MM-DD            Search upper date bound, or prune cutoff.
      --dry-run                     Report prune impact without changing files.
      --include-pinned              Prune/bulk-delete pinned content too. Pinned
                                    clips are exempt by default.
      --bundle-id ID                Bulk criterion: source app bundle id.
      --app NAME                    Bulk criterion: source app display name.
      --type TYPE                   Bulk criterion: content type (text/url/code/...).
      --sensitivity KIND            Bulk criterion: any-flagged | manual-restricted.
      --tail N                      logs: how many rows to print. Default: 50.
      --errors                      logs: only rows recorded at error level.
      --verbose                     Print ignored non-text changes.
      --json                        JSON output for supported commands.

    This CLI does not install launch/login behavior. Capture only runs while
    the monitor command is active.
    """)
    }
    // The parsed command is the honest verb; the positional guess above
    // only has to cover an invocation that never parsed.
    recordCLICommand(
        options.operationalLog,
        verb: ClipboardOperationalLog.Verb(command: options.command),
        exitCode: 0
    )
} catch {
    FileHandle.standardError.write(Data("clipboard-archive error: \(error)\n".utf8))
    // The options may not have parsed, so this path resolves the log
    // directory the same way `parse` would have.
    recordCLICommand(
        ClipboardOperationalLog(directory: ClipboardStoreLocator.resolve().logDirectory),
        verb: cliVerb,
        exitCode: 1
    )
    exit(1)
}
