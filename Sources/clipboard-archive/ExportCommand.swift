import ClipboardArchiveCore
import Darwin
import Foundation

enum ExportCommand {
    /// Writes matching clips, content and all, to a file the caller names.
    ///
    /// This is the one command that puts real clipboard text on disk
    /// outside the archive, so it is deliberately awkward in three ways: it
    /// will not write to standard output, it will not overwrite without
    /// being told to, and it prints counts rather than content. What it
    /// leaves out is not a filter the caller chooses — clips marked
    /// restricted, by label or by hand, and clips that have been deleted,
    /// never go in the file.
    static func run(_ options: CLIOptions) throws -> ClipboardCLIExit {
        try CLIOutcome.rejectDryRun(options)
        guard let outPath = options.outPath else {
            throw CLIOutcomeError(exit: .usage, message: "export needs --out PATH")
        }
        guard outPath != "-" else {
            throw CLIOutcomeError(
                exit: .usage,
                message: "export will not write clipboard content to standard output; give --out a file path"
            )
        }
        let format = options.format ?? "ndjson"
        guard format == "ndjson" || format == "json" else {
            throw CLIOutcomeError(exit: .usage, message: "invalid value for --format (ndjson | json)")
        }
        try CLIOutcome.requireArchive(options)

        let outURL = URL(fileURLWithPath: outPath)
        // `lstat`, not `fileExists`: a dangling symlink is not "existing" to
        // the latter, and writing through one would put clipboard content
        // wherever it points.
        var entry = stat()
        if lstat(outURL.path, &entry) == 0 {
            if entry.st_mode & S_IFMT == S_IFLNK {
                throw CLIOutcomeError(
                    exit: .usage,
                    message: "\(outURL.path) is a symbolic link; give --out a real path"
                )
            }
            if entry.st_mode & S_IFMT != S_IFREG {
                throw CLIOutcomeError(
                    exit: .usage,
                    message: "\(outURL.path) is not a regular file; give --out a file path"
                )
            }
            if !options.force {
                throw CLIOutcomeError(
                    exit: .usage,
                    message: "\(outURL.path) already exists; pass --force to overwrite it"
                )
            }
        }

        let reader = ClipboardArchiveReader(archiveRoot: options.archiveRoot)
        let suppression = try ClipboardSuppression(archiveRoot: options.archiveRoot).snapshot()
        let restrictedHashes = ClipboardAnnotationsStore(archiveRoot: options.archiveRoot)
            .restrictedContentHashes()
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]

        var written = 0
        var excluded: [ClipboardExportExclusion: Int] = [:]
        var filteredOut = 0
        var rows: [Data] = []

        // Newest first, like every other read surface.
        outer: for fileURL in try reader.eventFiles().reversed() {
            let data = try Data(contentsOf: fileURL)
            for line in data.split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: true).reversed() {
                guard let event = try? decoder.decode(StoredClipboardEvent.self, from: line) else {
                    continue
                }
                // Filters first, so the exclusion counts describe the set
                // the caller asked for rather than the whole archive.
                guard matchesFilters(event, options) else {
                    filteredOut += 1
                    continue
                }
                let override = restrictedHashes.contains(event.contentHash) ? "restricted" : nil
                if let exclusion = ClipboardExportRules.exclusion(
                    for: event,
                    suppression: suppression,
                    sensitivityOverride: override
                ) {
                    excluded[exclusion, default: 0] += 1
                    continue
                }
                let content = (try? reader.content(for: event)) ?? event.contentPreview
                guard let row = try? encoder.encode(ExportRow(event: event, content: content)) else {
                    continue
                }
                rows.append(row)
                written += 1
                // No implicit cap: an export that quietly stopped at the
                // newest few would be the worst possible shape for the one
                // command whose output people keep as a copy.
                if let limit = options.limit, written >= limit {
                    break outer
                }
            }
        }

        try write(rows: rows, to: outURL, format: format)

        let summary: [String: Any] = [
            "schema": 1,
            "out": outURL.path,
            "format": format,
            "written": written,
            "excluded_restricted": (excluded[.restricted] ?? 0) + (excluded[.manuallyRestricted] ?? 0),
            "excluded_deleted": excluded[.suppressed] ?? 0,
            "filtered_out": filteredOut
        ]
        if options.json {
            CLIOutcome.printJSON(summary)
        } else {
            print("export written: \(outURL.path)")
            print("format: \(format)")
            print("written: \(written)")
            print("excluded_restricted: \(summary["excluded_restricted"] ?? 0)")
            print("excluded_deleted: \(summary["excluded_deleted"] ?? 0)")
            print("filtered_out: \(filteredOut)")
        }
        return .success
    }

    private static func write(rows: [Data], to url: URL, format: String) throws {
        var body = Data()
        if format == "ndjson" {
            for row in rows {
                body.append(row)
                body.append(0x0A)
            }
        } else {
            body.append(Data("[\n".utf8))
            for (offset, row) in rows.enumerated() {
                body.append(row)
                body.append(Data((offset == rows.count - 1 ? "\n" : ",\n").utf8))
            }
            body.append(Data("]\n".utf8))
        }
        // Created owner-only from the start: a file that is briefly world
        // readable is world readable.
        guard FileManager.default.createFile(
            atPath: url.path,
            contents: body,
            attributes: [.posixPermissions: NSNumber(value: ClipboardExportRules.filePermissions)]
        ) else {
            // Reported, never assumed: the call returns false for a path it
            // cannot create, and treating that as written would leave the
            // command claiming an export that does not exist.
            throw CLIOutcomeError(exit: .runtime, message: "could not write \(url.path)")
        }
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: ClipboardExportRules.filePermissions)],
            ofItemAtPath: url.path
        )
    }

    private static func matchesFilters(_ event: StoredClipboardEvent, _ options: CLIOptions) -> Bool {
        if let since = options.since, event.capturedAt < since {
            return false
        }
        if let until = options.until, event.capturedAt > until {
            return false
        }
        if let app = options.appName, event.sourceApp.name != app {
            return false
        }
        if let bundleID = options.bundleID, event.sourceApp.bundleIdentifier != bundleID {
            return false
        }
        if let type = options.contentType, event.contentType.rawValue != type {
            return false
        }
        return true
    }

    private struct ExportRow: Encodable {
        var schema = 1
        var id: String
        var capturedAt: Date
        var sourceApp: String
        var bundleID: String?
        var contentType: String
        var contentHash: String
        var byteCount: Int
        var content: String

        init(event: StoredClipboardEvent, content: String) {
            id = event.id
            capturedAt = event.capturedAt
            sourceApp = event.sourceApp.name
            bundleID = event.sourceApp.bundleIdentifier
            contentType = event.contentType.rawValue
            contentHash = event.contentHash
            byteCount = event.byteCount
            self.content = content
        }
    }
}

enum StatsCommand {
    static func run(_ options: CLIOptions) throws -> ClipboardCLIExit {
        try CLIOutcome.requireArchive(options)
        let rows = try StatusCommand.readUsageRows(archiveRoot: options.archiveRoot)
        // limit 0 means "every retained row": counting heartbeats out of a
        // capped read would report a number that is really the cap.
        let heartbeats = options.operationalLog
            .read(limit: 0, since: options.since)
            .filter { $0.code == "heartbeat" }
            .count
        let summary = ClipboardUsageStats.summarize(
            usage: rows,
            heartbeats: heartbeats,
            since: options.since
        )

        if options.json {
            let formatter = ISO8601DateFormatter()
            CLIOutcome.printJSON([
                "schema": 1,
                "days": summary.days.map {
                    [
                        "day": $0.day,
                        "captures": $0.captures,
                        "blocked": $0.blocked,
                        "search_hits": $0.searchHits,
                        "search_misses": $0.searchMisses,
                        "errors": $0.errors
                    ]
                },
                "search_latency": summary.searchLatency.mapValues {
                    [
                        "samples": $0.samples,
                        "p50_ms": $0.p50Ms,
                        "p90_ms": $0.p90Ms,
                        "max_ms": $0.maxMs
                    ]
                },
                "total_captures": summary.totalCaptures,
                "total_blocked": summary.totalBlocked,
                "total_searches": summary.totalSearches,
                "total_errors": summary.totalErrors,
                "heartbeats": summary.heartbeats,
                "first_row": summary.firstRow.map { formatter.string(from: $0) as Any } ?? NSNull(),
                "last_row": summary.lastRow.map { formatter.string(from: $0) as Any } ?? NSNull()
            ])
            return .success
        }

        print("Clipboard Archive stats")
        print("captures: \(summary.totalCaptures)  blocked: \(summary.totalBlocked)  searches: \(summary.totalSearches)  errors: \(summary.totalErrors)  heartbeats: \(summary.heartbeats)")
        print("")
        print("day         captures  blocked  hits  misses  errors")
        for day in summary.days {
            print("\(day.day)  \(pad(day.captures, 8))  \(pad(day.blocked, 7))  \(pad(day.searchHits, 4))  \(pad(day.searchMisses, 6))  \(pad(day.errors, 6))")
        }
        if !summary.searchLatency.isEmpty {
            print("")
            print("search latency (ms)")
            for scope in summary.searchLatency.keys.sorted() {
                guard let latency = summary.searchLatency[scope] else {
                    continue
                }
                print("\(scope): n=\(latency.samples) p50=\(round(latency.p50Ms)) p90=\(round(latency.p90Ms)) max=\(round(latency.maxMs))")
            }
        }
        return .success
    }

    private static func pad(_ value: Int, _ width: Int) -> String {
        let text = String(value)
        return String(repeating: " ", count: max(0, width - text.count)) + text
    }

    private static func round(_ value: Double) -> Int {
        Int(value.rounded())
    }
}
