import Foundation

public struct ClipboardArchiveHealth: Codable, Equatable, Sendable {
    public var archiveRoot: String
    public var generatedAt: Date
    public var storedEvents: Int
    public var blockedEvents: Int
    public var deletedEvents: Int
    public var largeBodyFiles: Int
    public var missingBodyFiles: Int
    public var invalidJSONLines: Int
    public var archiveBytes: Int64
    public var indexBytes: Int64
    public var latestCapturedAt: Date?
    public var todayStoredEvents: Int
    public var lastSevenDaysStoredEvents: Int
    public var indexExists: Bool
    public var indexModifiedAt: Date?
    public var indexIsStale: Bool
}

public struct ClipboardDailyManifest: Codable, Equatable, Sendable {
    public var manifestDate: String
    public var generatedAt: Date
    public var storedEvents: Int
    public var blockedEvents: Int
    public var deletedEvents: Int
    public var largeBodyFiles: Int
    public var missingBodyFiles: Int
    public var archiveBytes: Int64
    public var latestCapturedAt: Date?
}

public struct ClipboardArchiveHealthReporter: Sendable {
    public var archiveRoot: URL
    public var indexURL: URL

    public init(
        archiveRoot: URL,
        indexURL: URL = ClipboardDefaults.indexURL()
    ) {
        self.archiveRoot = archiveRoot
        self.indexURL = indexURL
    }

    public func health() throws -> ClipboardArchiveHealth {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let deleted = try ClipboardDeletionLedger(archiveRoot: archiveRoot).deletedIDs()
        let eventFiles = try ClipboardArchiveReader(archiveRoot: archiveRoot).eventFiles()
        let todayStart = Calendar.current.startOfDay(for: Date())
        let sevenDaysAgo = Calendar.current.date(byAdding: .day, value: -7, to: Date()) ?? Date()

        var storedEvents = 0
        var blockedEvents = 0
        var invalidJSONLines = 0
        var missingBodyFiles = 0
        var latestCapturedAt: Date?
        var todayStoredEvents = 0
        var lastSevenDaysStoredEvents = 0

        for eventFile in eventFiles {
            let lines = try String(contentsOf: eventFile).split(separator: "\n", omittingEmptySubsequences: true)
            for line in lines {
                guard let data = String(line).data(using: .utf8) else {
                    invalidJSONLines += 1
                    continue
                }
                if let blocked = try? decoder.decode(BlockedClipboardEvent.self, from: data),
                   blocked.eventType == "blocked_sensitive_clipboard_item" {
                    blockedEvents += 1
                    continue
                }
                guard let event = try? decoder.decode(StoredClipboardEvent.self, from: data) else {
                    invalidJSONLines += 1
                    continue
                }
                storedEvents += 1
                if let currentLatest = latestCapturedAt {
                    latestCapturedAt = max(currentLatest, event.capturedAt)
                } else {
                    latestCapturedAt = event.capturedAt
                }
                if event.capturedAt >= todayStart {
                    todayStoredEvents += 1
                }
                if event.capturedAt >= sevenDaysAgo {
                    lastSevenDaysStoredEvents += 1
                }
                if let rawContentPath = event.rawContentPath,
                   !FileManager.default.fileExists(atPath: archiveRoot.appendingPathComponent(rawContentPath).path) {
                    missingBodyFiles += 1
                }
            }
        }

        let indexModifiedAt = modifiedAt(indexURL)
        let indexExists = FileManager.default.fileExists(atPath: indexURL.path)
        let indexIsStale: Bool
        if let latestCapturedAt, let indexModifiedAt {
            indexIsStale = indexModifiedAt < latestCapturedAt
        } else {
            indexIsStale = storedEvents > 0 && !indexExists
        }

        return ClipboardArchiveHealth(
            archiveRoot: archiveRoot.path,
            generatedAt: Date(),
            storedEvents: storedEvents,
            blockedEvents: blockedEvents,
            deletedEvents: deleted.count,
            largeBodyFiles: try countFiles(archiveRoot.appendingPathComponent("raw"), suffix: ".code")
                + countFiles(archiveRoot.appendingPathComponent("raw"), suffix: ".txt"),
            missingBodyFiles: missingBodyFiles,
            invalidJSONLines: invalidJSONLines,
            archiveBytes: directorySize(archiveRoot),
            indexBytes: fileSize(indexURL),
            latestCapturedAt: latestCapturedAt,
            todayStoredEvents: todayStoredEvents,
            lastSevenDaysStoredEvents: lastSevenDaysStoredEvents,
            indexExists: indexExists,
            indexModifiedAt: indexModifiedAt,
            indexIsStale: indexIsStale
        )
    }

    public func writeDailyManifest(for date: Date = Date()) throws -> URL {
        let health = try health()
        let day = dayString(date)
        let manifest = ClipboardDailyManifest(
            manifestDate: day,
            generatedAt: Date(),
            storedEvents: health.storedEvents,
            blockedEvents: health.blockedEvents,
            deletedEvents: health.deletedEvents,
            largeBodyFiles: health.largeBodyFiles,
            missingBodyFiles: health.missingBodyFiles,
            archiveBytes: health.archiveBytes,
            latestCapturedAt: health.latestCapturedAt
        )
        let url = archiveRoot
            .appendingPathComponent("manifests")
            .appendingPathComponent("\(day)_manifest.json")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(manifest).write(to: url, options: [.atomic])
        return url
    }

    private func countFiles(_ root: URL, suffix: String) throws -> Int {
        guard FileManager.default.fileExists(atPath: root.path) else {
            return 0
        }
        let urls = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey])?.compactMap { $0 as? URL } ?? []
        return try urls.filter { url in
            let values = try url.resourceValues(forKeys: [.isRegularFileKey])
            return values.isRegularFile == true && url.lastPathComponent.hasSuffix(suffix)
        }.count
    }

    private func directorySize(_ root: URL) -> Int64 {
        guard FileManager.default.fileExists(atPath: root.path) else {
            return 0
        }
        let urls = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey])?.compactMap { $0 as? URL } ?? []
        return urls.reduce(Int64(0)) { total, url in
            guard let values = try? url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]),
                  values.isRegularFile == true else {
                return total
            }
            return total + Int64(values.fileSize ?? 0)
        }
    }

    private func fileSize(_ url: URL) -> Int64 {
        guard let values = try? url.resourceValues(forKeys: [.fileSizeKey]) else {
            return 0
        }
        return Int64(values.fileSize ?? 0)
    }

    private func modifiedAt(_ url: URL) -> Date? {
        try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
    }

    private func dayString(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }
}
