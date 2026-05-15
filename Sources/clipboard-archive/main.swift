import ClipboardArchiveCore
import AppKit
import Foundation

struct CLIOptions {
    var command: String
    var positional: [String]
    var archiveRoot: URL
    var intervalSeconds: TimeInterval
    var durationSeconds: TimeInterval?
    var inlineLimitBytes: Int
    var limit: Int
    var since: Date?
    var until: Date?
    var verbose: Bool
    var json: Bool
    var dryRun: Bool

    static func parse(_ arguments: [String]) throws -> CLIOptions {
        var args = Array(arguments.dropFirst())
        let command = args.first ?? "help"
        if !args.isEmpty {
            args.removeFirst()
        }

        var positional: [String] = []
        var archiveRoot = ClipboardDefaults.archiveRoot()
        var intervalSeconds: TimeInterval = 1.0
        var durationSeconds: TimeInterval?
        var inlineLimitBytes = 64 * 1024
        var limit = 25
        var since: Date?
        var until: Date?
        var verbose = false
        var json = false
        var dryRun = false

        var index = 0
        while index < args.count {
            let arg = args[index]
            switch arg {
            case "--archive-root":
                index += 1
                guard index < args.count else { throw CLIError.missingValue("--archive-root") }
                archiveRoot = URL(fileURLWithPath: args[index])
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
            case "--verbose":
                verbose = true
            case "--json":
                json = true
            case "--dry-run":
                dryRun = true
            default:
                if arg.hasPrefix("--") {
                    throw CLIError.unknownArgument(arg)
                }
                positional.append(arg)
            }
            index += 1
        }

        return CLIOptions(
            command: command,
            positional: positional,
            archiveRoot: archiveRoot,
            intervalSeconds: intervalSeconds,
            durationSeconds: durationSeconds,
            inlineLimitBytes: inlineLimitBytes,
            limit: limit,
            since: since,
            until: until,
            verbose: verbose,
            json: json,
            dryRun: dryRun
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

    var description: String {
        switch self {
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
        case let .stored(event):
            print("stored \(event.id) \(event.byteCount)b \(event.sourceApp.name)")
        case let .blocked(reason):
            print("blocked \(reason)")
        }
    }
}

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
        ingestor: ClipboardIngestor(archiveWriter: writer),
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
    let result = try ClipboardArchiveRedactor(archiveRoot: options.archiveRoot).redact(eventID: id)
    print("redacted \(result.eventID)")
    print("event file: \(result.redactedEventFile)")
    if let deletedBodyFile = result.deletedBodyFile {
        print("deleted body: \(deletedBodyFile)")
    }

case "prune":
    guard let before = options.until ?? options.since ?? options.positional.first.flatMap(CLIOptions.parseDate) else {
        throw CLIError.missingValue("prune cutoff date; use --until YYYY-MM-DD")
    }
    let result = try ClipboardArchivePruner(archiveRoot: options.archiveRoot)
        .pruneContent(before: before, dryRun: options.dryRun)
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
    }

case "repair-index":
    let index = ClipboardDerivedIndex(archiveRoot: options.archiveRoot)
    let count = try index.rebuild()
    print("index rebuilt: \(count) item(s)")
    print("index path: \(index.indexURL.path)")

case "index-search":
    guard let query = options.positional.first else {
        throw CLIError.missingValue("search query")
    }
    let output = try ClipboardDerivedIndex(archiveRoot: options.archiveRoot).search(query, limit: options.limit)
    print(output.isEmpty ? "no matches" : output)

case "health":
    let reporter = ClipboardArchiveHealthReporter(archiveRoot: options.archiveRoot)
    let health = try reporter.health()
    if options.json {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        print(String(data: try encoder.encode(health), encoding: .utf8) ?? "{}")
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
        print("invalid_json: \(health.invalidJSONLines)")
        print("archive_bytes: \(health.archiveBytes)")
        print("index_bytes: \(health.indexBytes)")
        print("index_stale: \(health.indexIsStale)")
        if let latest = health.latestCapturedAt {
            print("latest_captured_at: \(ISO8601DateFormatter().string(from: latest))")
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
      repair-index Rebuild the derived SQLite FTS search index.
      index-search QUERY Search the derived SQLite FTS index.
      health       Report archive/index health.
      write-manifest Write today's daily manifest.

    Monitor options:
      --duration SECONDS            Stop after this many seconds.
      --interval SECONDS            Polling interval. Default: 1.
      --archive-root PATH           Default: ~/Library/Application Support/ClipboardArchive/Archive/clipboard-history
      --inline-limit-bytes BYTES    Default: 65536. Larger content uses body files.
      --limit N                     Search result limit. Default: 25.
      --since YYYY-MM-DD            Search lower date bound.
      --until YYYY-MM-DD            Search upper date bound, or prune cutoff.
      --dry-run                     Report prune impact without changing files.
      --verbose                     Print ignored non-text changes.
      --json                        JSON output for supported commands.

    This CLI does not install launch/login behavior. Capture only runs while
    the monitor command is active.
    """)
    }
} catch {
    FileHandle.standardError.write(Data("clipboard-archive error: \(error)\n".utf8))
    exit(1)
}
