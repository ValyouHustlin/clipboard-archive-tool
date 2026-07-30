import Foundation

public struct ClipboardArchiveHealth: Codable, Equatable, Sendable {
    public var archiveRoot: String
    public var generatedAt: Date
    public var storedEvents: Int
    public var blockedEvents: Int
    public var deletedEvents: Int
    public var largeBodyFiles: Int
    public var missingBodyFiles: Int
    public var unsafeBodyPaths: Int
    public var insecureFiles: Int
    public var invalidJSONLines: Int
    public var archiveBytes: Int64
    public var indexBytes: Int64
    public var latestCapturedAt: Date?
    public var todayStoredEvents: Int
    public var lastSevenDaysStoredEvents: Int
    public var indexExists: Bool
    public var indexModifiedAt: Date?
    public var indexIsStale: Bool
    // Slice 5 dashboard extensions.
    public var bodyFileBytes: Int64
    public var eventFileCount: Int
    public var oldestCapturedAt: Date?
    /// Live events that are stored-but-never-searchable: `.restricted`
    /// label or a manual "restricted" annotation override.
    public var restrictedEvents: Int
    public var pinnedItems: Int
    public var taggedItems: Int
    public var expiringItems: Int
    /// The index database's `PRAGMA user_version`; nil when the index file
    /// is missing or unreadable.
    public var indexUserVersion: Int?
    public var annotationsBytes: Int64
    // Slice 6 rich-format extensions.
    /// Live events carrying rich content (image/rtf/file-list/color/link).
    public var richContentEvents: Int = 0
    /// Rich-extension body files under `raw/` referenced by NO live event
    /// line. The known producer is an OLD build redacting a v2 event: it
    /// drops `richContent` from the rewritten line without deleting the
    /// body (documented forward-compat gap; recovery = manual cleanup).
    public var orphanedRichBodyFiles: Int = 0
}

public struct ClipboardDailyManifest: Codable, Equatable, Sendable {
    public var schemaVersion: Int
    public var manifestDate: String
    public var generatedAt: Date
    public var storedEvents: Int
    public var blockedEvents: Int
    public var deletedEvents: Int
    public var largeBodyFiles: Int
    public var missingBodyFiles: Int
    public var unsafeBodyPaths: Int
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

    public func health(now: Date = Date(), calendar: Calendar = .current) throws -> ClipboardArchiveHealth {
        let annotationsStore = ClipboardAnnotationsStore(archiveRoot: archiveRoot)
        let annotationsDocument = annotationsStore.document()
        let restrictedHashes = Set(
            annotationsDocument.annotations
                .filter { $0.value.sensitivityOverride == "restricted" }
                .keys
        )
        let metrics = try scanEvents(in: nil, restrictedHashes: restrictedHashes)
        let todayStart = calendar.startOfDay(for: now)
        let sevenDaysAgo = calendar.date(byAdding: .day, value: -7, to: now) ?? now
        let currentUpperBound = now.addingTimeInterval(0.001)
        let today = try scanEvents(in: DateInterval(start: todayStart, end: currentUpperBound))
        let lastSevenDays = try scanEvents(in: DateInterval(start: sevenDaysAgo, end: currentUpperBound))
        let indexModifiedAt = modifiedAt(indexURL)
        let indexExists = FileManager.default.fileExists(atPath: indexURL.path)
        let indexIsStale: Bool
        if let latestCapturedAt = metrics.latestCapturedAt, let indexModifiedAt {
            indexIsStale = indexModifiedAt < latestCapturedAt
        } else {
            indexIsStale = metrics.storedEvents > 0 && !indexExists
        }

        return ClipboardArchiveHealth(
            archiveRoot: archiveRoot.path,
            generatedAt: now,
            storedEvents: metrics.storedEvents,
            blockedEvents: metrics.blockedEvents,
            deletedEvents: try ClipboardDeletionLedger(archiveRoot: archiveRoot).deletedIDs().count,
            largeBodyFiles: try countBodyFiles(),
            missingBodyFiles: metrics.missingBodyFiles,
            unsafeBodyPaths: metrics.unsafeBodyPaths,
            insecureFiles: insecureFileCount(),
            invalidJSONLines: metrics.invalidJSONLines,
            archiveBytes: directorySize(archiveRoot),
            indexBytes: fileSize(indexURL),
            latestCapturedAt: metrics.latestCapturedAt,
            todayStoredEvents: today.storedEvents,
            lastSevenDaysStoredEvents: lastSevenDays.storedEvents,
            indexExists: indexExists,
            indexModifiedAt: indexModifiedAt,
            indexIsStale: indexIsStale,
            bodyFileBytes: bodyFileBytes(),
            eventFileCount: (try? ClipboardArchiveReader(archiveRoot: archiveRoot).eventFiles().count) ?? 0,
            oldestCapturedAt: metrics.oldestCapturedAt,
            restrictedEvents: metrics.restrictedEvents,
            pinnedItems: annotationsDocument.annotations.filter { $0.value.pinned }.count,
            taggedItems: annotationsDocument.annotations.filter { !$0.value.tags.isEmpty }.count,
            expiringItems: annotationsDocument.annotations.filter { $0.value.expiresAt != nil }.count,
            indexUserVersion: ClipboardDerivedIndex(archiveRoot: archiveRoot, indexURL: indexURL)
                .userVersion(),
            annotationsBytes: fileSize(annotationsStore.annotationsFileURL),
            richContentEvents: metrics.richContentEvents,
            orphanedRichBodyFiles: orphanedRichBodyCount(
                referencedBodyPaths: metrics.referencedBodyRelativePaths
            )
        )
    }

    /// Rich-extension files under `raw/` not referenced by any event line
    /// (Slice 6). Text bodies (.code/.txt) are excluded: pre-Slice-6
    /// tombstones already handled them, so counting them here would flag
    /// history noise instead of the old-build rich-body orphaning gap.
    private func orphanedRichBodyCount(referencedBodyPaths: Set<String>) -> Int {
        let root = archiveRoot.standardizedFileURL
        return regularFiles(under: root.appendingPathComponent("raw"))
            .filter { ["png", "tiff", "rtf", "json"].contains($0.pathExtension) }
            .filter { url in
                let path = url.standardizedFileURL.path
                guard path.hasPrefix(root.path + "/") else {
                    return false
                }
                let relativePath = String(path.dropFirst(root.path.count + 1))
                return !referencedBodyPaths.contains(relativePath)
            }
            .count
    }

    public func writeDailyManifest(for date: Date = Date(), calendar: Calendar = .current) throws -> URL {
        let start = calendar.startOfDay(for: date)
        let end = calendar.date(byAdding: .day, value: 1, to: start) ?? date.addingTimeInterval(86_400)
        let interval = DateInterval(start: start, end: end)
        let metrics = try scanEvents(in: interval)
        let day = dayString(date, calendar: calendar)
        let manifest = ClipboardDailyManifest(
            schemaVersion: 2,
            manifestDate: day,
            generatedAt: Date(),
            storedEvents: metrics.storedEvents,
            blockedEvents: metrics.blockedEvents,
            deletedEvents: try deletionCount(in: interval),
            largeBodyFiles: metrics.referencedBodyFiles,
            missingBodyFiles: metrics.missingBodyFiles,
            unsafeBodyPaths: metrics.unsafeBodyPaths,
            archiveBytes: directorySize(archiveRoot),
            latestCapturedAt: metrics.latestCapturedAt
        )
        let url = archiveRoot
            .appendingPathComponent("manifests")
            .appendingPathComponent("\(day)_manifest.json")
        try ClipboardPrivateFileSystem.createDirectory(
            url.deletingLastPathComponent(),
            archiveRoot: archiveRoot
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(manifest).write(to: url, options: [.atomic])
        try ClipboardPrivateFileSystem.secureFile(url)
        return url
    }

    private struct EventMetrics {
        var storedEvents = 0
        var blockedEvents = 0
        var referencedBodyFiles = 0
        var missingBodyFiles = 0
        var unsafeBodyPaths = 0
        var invalidJSONLines = 0
        var latestCapturedAt: Date?
        var oldestCapturedAt: Date?
        var restrictedEvents = 0
        var richContentEvents = 0
        /// Every body path referenced by ANY decoded line (interval-
        /// independent), for the orphaned-rich-body diff.
        var referencedBodyRelativePaths: Set<String> = []
    }

    private func scanEvents(
        in interval: DateInterval?,
        restrictedHashes: Set<String> = []
    ) throws -> EventMetrics {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        var metrics = EventMetrics()

        for eventFile in try ClipboardArchiveReader(archiveRoot: archiveRoot).eventFiles() {
            let lines = try String(contentsOf: eventFile)
                .split(separator: "\n", omittingEmptySubsequences: true)
            for line in lines {
                guard let data = String(line).data(using: .utf8) else {
                    metrics.invalidJSONLines += 1
                    continue
                }
                if let blocked = try? decoder.decode(BlockedClipboardEvent.self, from: data),
                   blocked.eventType == "blocked_sensitive_clipboard_item" {
                    if interval.map({ $0.contains(blocked.capturedAt) }) ?? true {
                        metrics.blockedEvents += 1
                    }
                    continue
                }
                guard let event = try? decoder.decode(StoredClipboardEvent.self, from: data) else {
                    metrics.invalidJSONLines += 1
                    continue
                }
                // Interval-independent: paths referenced by ANY line (live
                // or out of window) so the orphan diff never miscounts.
                if let rawContentPath = event.rawContentPath {
                    metrics.referencedBodyRelativePaths.insert(rawContentPath)
                }
                if let richBodyPath = event.richContent?.bodyPath {
                    metrics.referencedBodyRelativePaths.insert(richBodyPath)
                }
                guard interval.map({ $0.contains(event.capturedAt) }) ?? true else {
                    continue
                }

                metrics.storedEvents += 1
                metrics.latestCapturedAt = metrics.latestCapturedAt.map { max($0, event.capturedAt) } ?? event.capturedAt
                metrics.oldestCapturedAt = metrics.oldestCapturedAt.map { min($0, event.capturedAt) } ?? event.capturedAt
                if event.privacyLabel == .restricted || restrictedHashes.contains(event.contentHash) {
                    metrics.restrictedEvents += 1
                }
                if event.richContent != nil {
                    metrics.richContentEvents += 1
                }

                // Plain-text body plus the rich body (Slice 6): both are
                // containment-checked and both count toward missing/unsafe.
                for bodyPath in [event.rawContentPath, event.richContent?.bodyPath] {
                    guard let bodyPath else {
                        continue
                    }
                    metrics.referencedBodyFiles += 1
                    do {
                        let bodyURL = try ClipboardArchivePath.containedURL(
                            relativePath: bodyPath,
                            archiveRoot: archiveRoot
                        )
                        if !FileManager.default.fileExists(atPath: bodyURL.path) {
                            metrics.missingBodyFiles += 1
                        }
                    } catch {
                        metrics.unsafeBodyPaths += 1
                    }
                }
            }
        }
        return metrics
    }

    private func deletionCount(in interval: DateInterval) throws -> Int {
        let root = archiveRoot.appendingPathComponent("deletion-ledger")
        guard FileManager.default.fileExists(atPath: root.path) else {
            return 0
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let urls = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles]
        )?.compactMap { $0 as? URL } ?? []

        var count = 0
        for url in urls where url.pathExtension == "ndjson" {
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard values.isRegularFile == true, values.isSymbolicLink != true else {
                continue
            }
            for line in try String(contentsOf: url).split(separator: "\n", omittingEmptySubsequences: true) {
                guard let data = String(line).data(using: .utf8),
                      let event = try? decoder.decode(ClipboardDeletionEvent.self, from: data),
                      interval.contains(event.deletedAt) else {
                    continue
                }
                count += 1
            }
        }
        return count
    }

    private func countBodyFiles() throws -> Int {
        let root = archiveRoot.appendingPathComponent("raw")
        guard FileManager.default.fileExists(atPath: root.path) else {
            return 0
        }
        let urls = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey]
        )?.compactMap { $0 as? URL } ?? []
        return try urls.filter { url in
            let values = try url.resourceValues(forKeys: [.isRegularFileKey])
            return values.isRegularFile == true && Self.bodyFileExtensions.contains(url.pathExtension)
        }.count
    }

    /// Body-file extensions under `raw/`: text bodies plus the Slice 6 rich
    /// bodies (image/RTF/spilled-file-list).
    static let bodyFileExtensions: Set<String> = ["code", "txt", "png", "tiff", "rtf", "json"]

    /// Total bytes of large-item body files under `raw/` (Slice 5
    /// dashboard). Counting matches `countBodyFiles` (same extensions).
    private func bodyFileBytes() -> Int64 {
        let root = archiveRoot.appendingPathComponent("raw")
        return regularFiles(under: root)
            .filter { Self.bodyFileExtensions.contains($0.pathExtension) }
            .reduce(Int64(0)) { total, url in
                guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize else {
                    return total
                }
                return total + Int64(size)
            }
    }

    private func insecureFileCount() -> Int {
        let archiveFiles = regularFiles(under: archiveRoot)
        let candidates = archiveFiles + (FileManager.default.fileExists(atPath: indexURL.path) ? [indexURL] : [])
        var count = 0
        for url in candidates {
            guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
                  let permissions = attributes[.posixPermissions] as? NSNumber else {
                continue
            }
            if permissions.intValue & 0o077 != 0 {
                count += 1
            }
        }
        return count
    }

    private func regularFiles(under root: URL) -> [URL] {
        guard FileManager.default.fileExists(atPath: root.path) else {
            return []
        }
        let urls = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey]
        )?.compactMap { $0 as? URL } ?? []
        return urls.filter {
            (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
        }
    }

    private func directorySize(_ root: URL) -> Int64 {
        regularFiles(under: root).reduce(Int64(0)) { total, url in
            guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize else {
                return total
            }
            return total + Int64(size)
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

    private func dayString(_ date: Date, calendar: Calendar) -> String {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }
}
