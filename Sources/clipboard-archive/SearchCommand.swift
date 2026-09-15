import ClipboardArchiveCore
import Foundation

enum SearchCommand {
    /// The index-backed search, using the matcher the history window uses.
    ///
    /// Before this, `search` scanned the raw day files with a different
    /// matcher from the app's, so the same query could report different
    /// hits in the two places. `--scan` keeps the raw-archive path for the
    /// case it is actually good for: no index, or an index you do not
    /// trust.
    static func run(_ options: CLIOptions) throws -> ClipboardCLIExit {
        guard let query = options.positional.first else {
            throw CLIOutcomeError(exit: .usage, message: "search needs a query")
        }
        try CLIOutcome.requireArchive(options)

        if options.scan {
            return try runScan(options, query: query)
        }

        // No index check here on purpose: `structuredSearch` rebuilds a
        // missing or out-of-date index before it answers, and refusing
        // first would turn a self-healing case into a failure.
        let index = ClipboardDerivedIndex(
            archiveRoot: options.archiveRoot,
            indexURL: options.indexPath,
            operationalLog: options.operationalLog
        )
        let results = try index.structuredSearch(
            query,
            filters: ClipboardIndexSearchFilters(
                since: options.since,
                until: options.until,
                bundleID: options.bundleID,
                sourceAppName: options.appName,
                contentType: options.contentType
            ),
            limit: options.limit ?? 25
        )

        if options.json {
            let formatter = ISO8601DateFormatter()
            let rows: [[String: Any]] = results.map { result in
                [
                    "id": result.id,
                    "captured_at": formatter.string(from: result.capturedAt),
                    "app": result.sourceApp,
                    "bundle_id": result.bundleID as Any? ?? NSNull(),
                    "type": result.contentType,
                    "snippet": result.snippet,
                    "bytes": result.byteCount
                ]
            }
            CLIOutcome.printJSON(["schema": 1, "results": rows])
            return .success
        }

        if results.isEmpty {
            print("no matches")
            return .success
        }
        let formatter = ISO8601DateFormatter()
        for result in results {
            print("\(formatter.string(from: result.capturedAt)) \(result.id) \(result.sourceApp)")
            print(result.snippet)
            print("")
        }
        return .success
    }

    private static func runScan(_ options: CLIOptions, query: String) throws -> ClipboardCLIExit {
        let searcher = ClipboardArchiveSearcher(archiveRoot: options.archiveRoot)
        // The raw-archive searcher only understands dates, so the app,
        // bundle and type filters are applied here rather than quietly
        // ignored — a result set wider than the one asked for is worse than
        // a slower one. The limit is applied after them, for the same
        // reason.
        let limit = options.limit ?? 25
        let results = try searcher.search(ClipboardSearchOptions(
            query: query,
            since: options.since,
            until: options.until,
            limit: Int.max
        )).filter { result in
            let event = result.event
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
        }.prefix(limit)
        if options.json {
            let formatter = ISO8601DateFormatter()
            let rows: [[String: Any]] = results.map { result in
                [
                    "id": result.event.id,
                    "captured_at": formatter.string(from: result.event.capturedAt),
                    "app": result.event.sourceApp.name,
                    "bundle_id": result.event.sourceApp.bundleIdentifier as Any? ?? NSNull(),
                    "type": result.event.contentType.rawValue,
                    "snippet": result.snippet,
                    "bytes": result.event.byteCount
                ]
            }
            CLIOutcome.printJSON(["schema": 1, "results": rows])
            return .success
        }
        if results.isEmpty {
            print("no matches")
            return .success
        }
        let formatter = ISO8601DateFormatter()
        for result in results {
            let event = result.event
            print("\(formatter.string(from: event.capturedAt)) \(event.id) \(event.sourceApp.name) \(result.matchedInBody ? "body" : "meta")")
            print(result.snippet)
            print("")
        }
        return .success
    }
}
