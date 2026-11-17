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
    /// nil when the caller did not ask for one: `search` picks its own
    /// default, `export` writes everything that matches.
    var limit: Int?
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
    /// `search --scan`: read the raw day files instead of the index.
    var scan: Bool
    /// `export` flags.
    var outPath: String?
    var format: String?
    var force: Bool
    /// `help --markdown`.
    var markdown: Bool
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
        var limit: Int?
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
        var scan = false
        var outPath: String?
        var format: String?
        var force = false
        var markdown = false

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
            case "--scan":
                scan = true
            case "--force":
                force = true
            case "--markdown":
                markdown = true
            case "--out":
                index += 1
                guard index < args.count, !args[index].isEmpty else {
                    throw CLIError.missingValue("--out")
                }
                outPath = args[index]
            case "--format":
                index += 1
                guard index < args.count, !args[index].isEmpty else {
                    throw CLIError.missingValue("--format")
                }
                format = args[index]
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
            scan: scan,
            outPath: outPath,
            format: format,
            force: force,
            markdown: markdown,
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

    /// Returns how many stored clips the index did not take, so the caller
    /// can exit 5 rather than claim a clean run.
    @discardableResult
    func run() throws -> Int {
        var lastChangeCount = pasteboard.changeCount
        var lastContentHash: String?
        var indexProblems = 0
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
                return indexProblems
            }

            let changeCount = pasteboard.changeCount
            if changeCount != lastChangeCount {
                lastChangeCount = changeCount
                if let capture = readTextCapture() {
                    let contentHash = String(capture.content.hashValue)
                    if contentHash != lastContentHash {
                        lastContentHash = contentHash
                        indexProblems += try ingest(capture) ? 1 : 0
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

    /// True when the clip was stored but the index did not take it.
    private func ingest(_ capture: ClipboardCapture) throws -> Bool {
        let result = try ingestor.ingest(capture)
        switch result {
        case let .stored(event, indexUpdate):
            print("stored \(event.id) \(event.byteCount)b \(event.sourceApp.name)")
            if indexUpdate == .failed {
                FileHandle.standardError.write(
                    Data("warning: archive stored; incremental index update failed\n".utf8)
                )
                return true
            }
            if indexUpdate == .deferred {
                // Not counted against the run: a rebuild in progress will
                // pick this row up, and a scheduled monitor should not look
                // unhealthy for something that heals itself.
                FileHandle.standardError.write(
                    Data("warning: archive stored; index is rebuilding and will include it\n".utf8)
                )
                return false
            }
            return false
        case let .blocked(reason):
            print("blocked \(reason)")
            return false
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
        level: exitCode == 0 ? .info : (verb == .status || verb == .verify ? .warn : .error),
        count: exitCode,
        verb: verb
    )
}

let cliVerb = ClipboardOperationalLog.Verb(
    command: CommandLine.arguments.dropFirst().first ?? "help"
)

// Said before anything is parsed or read, because a half-isolated run
// produces output that looks valid and is measured against the wrong stores.
// stderr, so it cannot corrupt a `--json` consumer.
if let breach = ClipboardRuntime.isolationBreach() {
    FileHandle.standardError.write(Data("clipboard-archive: \(breach.sentence)\n".utf8))
}

/// What this invocation will exit with. New verbs assign it; the older
/// ones leave it at success and throw when they fail.
var cliExit = ClipboardCLIExit.success

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
    // The same app exclusions and per-app rules the app applies. Without
    // them this command stored and indexed clips the user had excluded.
    let monitorSettings = ClipboardSettingsStore(
        settingsURL: options.storeResolution.settingsURL
    ).loadReporting(readOnly: true).settings
    let monitor = PasteboardMonitor(
        pasteboard: .general,
        ingestor: ClipboardIngestor(
            filter: ClipboardPrivacyFilter(settings: monitorSettings),
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
    let indexProblems = try monitor.run()
    if indexProblems > 0 {
        FileHandle.standardError.write(
            Data("warning: \(indexProblems) stored clip(s) did not reach the index\n".utf8)
        )
        cliExit = .warnings
    }

case "search":
    cliExit = try SearchCommand.run(options)

case "redact":
    guard let id = options.positional.first else {
        throw CLIError.missingValue("clipboard event id")
    }
    try CLIOutcome.rejectDryRun(options)
    try CLIOutcome.requireArchive(options)
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
    try CLIOutcome.requireArchive(options)
    let result = try ClipboardArchivePruner(archiveRoot: options.archiveRoot, indexURL: options.indexPath)
        .pruneContent(before: before, dryRun: options.dryRun, includePinned: options.includePinned)
    if options.json {
        try CLIOutcome.printJSON(result, schema: 1)
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
    try CLIOutcome.requireArchive(options)
    let engine = ClipboardBulkEngine(archiveRoot: options.archiveRoot, indexURL: options.indexPath)
    let result = options.dryRun
        ? try engine.preview(criteria)
        : try engine.execute(criteria)
    if options.json {
        try CLIOutcome.printJSON(result, schema: 1)
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
    try CLIOutcome.rejectDryRun(options)
    try CLIOutcome.requireArchive(options)
    let sweeper = ClipboardExpirySweeper(archiveRoot: options.archiveRoot, indexURL: options.indexPath)
    let nextDue = sweeper.nextDue()
    if !options.json {
        print("next_due: \(nextDue.map { ISO8601DateFormatter().string(from: $0) } ?? "none")")
    }
    let result = try sweeper.sweepIfDue()
    if options.json {
        // Under --json the whole output is one document: a "next_due:" line
        // ahead of it made the output unparseable.
        try CLIOutcome.printJSON(
            result,
            schema: 1,
            extra: ["next_due": nextDue.map { ISO8601DateFormatter().string(from: $0) as Any } ?? NSNull()]
        )
    } else {
        print("swept_hashes: \(result.sweptContentHashes)")
        print("deleted_events: \(result.deletedEvents)")
        print("reclaimed_bytes: \(result.reclaimedBytes)")
    }

case "repair-index":
    try CLIOutcome.requireArchive(options)
    let index = ClipboardDerivedIndex(
        archiveRoot: options.archiveRoot,
        indexURL: options.indexPath,
        operationalLog: options.operationalLog
    )
    let count = try index.rebuild()
    print("index rebuilt: \(count) item(s)")
    print("index path: \(index.indexURL.path)")

case "index-search":
    // Kept working, and now the same code as `search`: two spellings of one
    // command cannot disagree about what matches.
    cliExit = try SearchCommand.run(options)

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
    try CLIOutcome.requireArchive(options)
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
        object["schema"] = 1
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
        print("{\n  \"schema\": 1,\n  \"rows\": [")
        print(entries.map { "    " + $0.line }.joined(separator: ",\n"))
        print("  ]\n}")
    } else if entries.isEmpty {
        print("no operational rows")
    } else {
        for entry in entries {
            print(entry.textDescription)
        }
    }

case "write-manifest":
    try CLIOutcome.requireArchive(options)
    let url = try ClipboardArchiveHealthReporter(
        archiveRoot: options.archiveRoot,
        indexURL: options.indexPath
    ).writeDailyManifest()
    print("manifest written: \(url.path)")

case "version":
    cliExit = VersionCommand.run(options)

case "status":
    cliExit = try StatusCommand.run(options)

case "verify":
    cliExit = try VerifyCommand.run(options)

case "doctor":
    cliExit = try DoctorCommand.run(options)

case "export":
    cliExit = try ExportCommand.run(options)

case "stats":
    cliExit = try StatsCommand.run(options)

case "help", "--help", "-h":
    if options.markdown {
        print(ClipboardCLIVerbs.markdownReference(), terminator: "")
    } else if let name = options.positional.first {
        guard let verb = ClipboardCLIVerbs.verb(named: name) else {
            throw CLIOutcomeError(exit: .usage, message: "unknown command \(name)")
        }
        print(ClipboardCLIVerbs.detail(for: verb))
    } else {
        print(ClipboardCLIVerbs.overview())
    }

default:
    // An unknown verb used to print the help and exit 0, which told a
    // script that a command it had misspelled had succeeded.
    throw CLIOutcomeError(exit: .usage, message: "unknown command \(options.command)")
    }
    // The parsed command is the honest verb; the positional guess above
    // only has to cover an invocation that never parsed.
    recordCLICommand(
        options.operationalLog,
        verb: ClipboardOperationalLog.Verb(command: options.command),
        exitCode: cliExit.rawValue
    )
    if cliExit != .success {
        exit(Int32(cliExit.rawValue))
    }
} catch {
    // One place decides what an error means to whatever ran this.
    let outcome: ClipboardCLIExit
    let message: String
    switch error {
    case let failure as CLIOutcomeError:
        outcome = failure.exit
        message = failure.message
    case let failure as CLIError:
        outcome = .usage
        message = failure.description
    case let failure as BackupCLIError:
        // A missing subcommand or file argument is a usage error (exit 2),
        // like every other malformed command line.
        if case .usage = failure {
            outcome = .usage
        } else {
            outcome = .runtime
        }
        message = failure.description
    default:
        outcome = .runtime
        message = "\(error)"
    }
    CLIOutcome.report(outcome, message, json: CommandLine.arguments.contains("--json"))
    // The options may not have parsed, so this path resolves the log
    // directory the same way `parse` would have.
    recordCLICommand(
        ClipboardOperationalLog(directory: ClipboardStoreLocator.resolve().logDirectory),
        verb: cliVerb,
        exitCode: outcome.rawValue
    )
    exit(Int32(outcome.rawValue))
}
