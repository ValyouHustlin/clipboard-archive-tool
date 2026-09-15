import Foundation

/// One decoded usage-log row, with only the fields the summary uses.
public struct ClipboardUsageRow: Sendable, Equatable {
    public var timestamp: Date
    public var event: String
    public var outcome: String
    public var scope: String
    public var count: Int
    public var durationMs: Double

    public init(
        timestamp: Date,
        event: String,
        outcome: String,
        scope: String,
        count: Int = 1,
        durationMs: Double = 0
    ) {
        self.timestamp = timestamp
        self.event = event
        self.outcome = outcome
        self.scope = scope
        self.count = count
        self.durationMs = durationMs
    }

    /// Decodes one NDJSON line, ignoring fields a newer writer may have
    /// added. A line that is not a usage row returns nil rather than
    /// throwing: a rotated file can end mid-row.
    public static func decode(line: Data) -> ClipboardUsageRow? {
        guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              let timestampText = object["timestamp"] as? String,
              let timestamp = ClipboardUsageRow.parseTimestamp(timestampText),
              let event = object["event"] as? String,
              let outcome = object["outcome"] as? String,
              let scope = object["scope"] as? String else {
            return nil
        }
        return ClipboardUsageRow(
            timestamp: timestamp,
            event: event,
            outcome: outcome,
            scope: scope,
            count: (object["count"] as? Int) ?? 1,
            durationMs: (object["durationMs"] as? Double) ?? 0
        )
    }

    private static func makeFormatter() -> ISO8601DateFormatter {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }

    /// The logs are written with fractional seconds, but a hand-made
    /// fixture may not be, so both spellings parse.
    public static func parseTimestamp(_ text: String) -> Date? {
        makeFormatter().date(from: text) ?? ISO8601DateFormatter().date(from: text)
    }
}

public struct ClipboardLatencySummary: Sendable, Equatable {
    public var samples: Int
    public var p50Ms: Double
    public var p90Ms: Double
    public var maxMs: Double
}

public struct ClipboardDayUsage: Sendable, Equatable {
    public var day: String
    public var captures: Int
    public var blocked: Int
    public var searchHits: Int
    public var searchMisses: Int
    public var errors: Int
}

public struct ClipboardUsageSummary: Sendable, Equatable {
    public var days: [ClipboardDayUsage]
    /// Search latency per scope, keyed by the scope as the log spells it.
    public var searchLatency: [String: ClipboardLatencySummary]
    public var totalCaptures: Int
    public var totalBlocked: Int
    public var totalSearches: Int
    public var totalErrors: Int
    public var heartbeats: Int
    public var firstRow: Date?
    public var lastRow: Date?
}

public enum ClipboardUsageStats {
    /// Everything `stats` reports, from rows that have already been read.
    ///
    /// Percentiles use the nearest-rank method on the sorted samples, which
    /// is the definition that does not invent a value no measurement
    /// produced. Days are UTC, like the archive's own day files, so a
    /// summary and the files it describes cannot disagree about a date.
    public static func summarize(
        usage: [ClipboardUsageRow],
        heartbeats: Int = 0,
        since: Date? = nil
    ) -> ClipboardUsageSummary {
        let rows = usage
            .filter { row in since.map { cutoff in row.timestamp >= cutoff } ?? true }
            .sorted { $0.timestamp < $1.timestamp }

        let formatter = dayFormatter()
        var byDay: [String: ClipboardDayUsage] = [:]
        var latencySamples: [String: [Double]] = [:]
        var totals = (captures: 0, blocked: 0, searches: 0, errors: 0)

        for row in rows {
            let day = formatter.string(from: row.timestamp)
            var summary = byDay[day] ?? ClipboardDayUsage(
                day: day, captures: 0, blocked: 0, searchHits: 0, searchMisses: 0, errors: 0
            )
            switch row.event {
            case "capture":
                summary.captures += max(1, row.count)
                totals.captures += max(1, row.count)
            case "blocked":
                summary.blocked += max(1, row.count)
                totals.blocked += max(1, row.count)
            case "search":
                totals.searches += 1
                if row.outcome == "miss" {
                    summary.searchMisses += 1
                } else {
                    summary.searchHits += 1
                }
                latencySamples[row.scope, default: []].append(row.durationMs)
            case "error":
                summary.errors += 1
                totals.errors += 1
            default:
                break
            }
            byDay[day] = summary
        }

        return ClipboardUsageSummary(
            days: byDay.values.sorted { $0.day < $1.day },
            searchLatency: latencySamples.mapValues(latency(of:)),
            totalCaptures: totals.captures,
            totalBlocked: totals.blocked,
            totalSearches: totals.searches,
            totalErrors: totals.errors,
            heartbeats: heartbeats,
            firstRow: rows.first?.timestamp,
            lastRow: rows.last?.timestamp
        )
    }

    /// The UTC day a timestamp falls in, spelled the way the summary keys
    /// its days — the archive's own day files use the same calendar.
    public static func dayKey(for date: Date) -> String {
        dayFormatter().string(from: date)
    }

    public static func latency(of samples: [Double]) -> ClipboardLatencySummary {
        guard !samples.isEmpty else {
            return ClipboardLatencySummary(samples: 0, p50Ms: 0, p90Ms: 0, maxMs: 0)
        }
        let sorted = samples.sorted()
        return ClipboardLatencySummary(
            samples: sorted.count,
            p50Ms: percentile(sorted, 0.5),
            p90Ms: percentile(sorted, 0.9),
            maxMs: sorted[sorted.count - 1]
        )
    }

    /// Nearest rank: the smallest sample at or above the requested share of
    /// the data. Never interpolates, so every number printed is one that was
    /// actually measured.
    private static func percentile(_ sorted: [Double], _ share: Double) -> Double {
        guard !sorted.isEmpty else {
            return 0
        }
        let rank = Int((share * Double(sorted.count)).rounded(.up))
        return sorted[min(max(rank, 1), sorted.count) - 1]
    }

    private static func dayFormatter() -> DateFormatter {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }
}
