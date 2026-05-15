import Foundation

public struct ClipboardDeletionEvent: Codable, Equatable, Sendable {
    public var eventType: String
    public var clipboardEventID: String
    public var deletedAt: Date
    public var reason: String

    public init(clipboardEventID: String, deletedAt: Date = Date(), reason: String) {
        self.eventType = "clipboard_event_deleted"
        self.clipboardEventID = clipboardEventID
        self.deletedAt = deletedAt
        self.reason = reason
    }
}

public struct ClipboardDeletionLedger: Sendable {
    public var archiveRoot: URL

    public init(archiveRoot: URL) {
        self.archiveRoot = archiveRoot
    }

    public func recordDeletion(eventID: String, reason: String = "manual-delete") throws {
        let event = ClipboardDeletionEvent(clipboardEventID: eventID, reason: reason)
        let url = ledgerURL(for: event.deletedAt)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        var data = try encoder.encode(event)
        data.append(0x0A)

        if FileManager.default.fileExists(atPath: url.path) {
            let handle = try FileHandle(forWritingTo: url)
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
            try handle.close()
        } else {
            try data.write(to: url, options: [.atomic])
        }
    }

    public func deletedIDs() throws -> Set<String> {
        let root = archiveRoot.appendingPathComponent("deletion-ledger")
        guard FileManager.default.fileExists(atPath: root.path) else {
            return []
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        var ids = Set<String>()
        let urls = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        )?.compactMap { $0 as? URL } ?? []

        for url in urls where url.pathExtension == "ndjson" {
            let lines = try String(contentsOf: url).split(separator: "\n", omittingEmptySubsequences: true)
            for line in lines {
                guard let data = String(line).data(using: .utf8),
                      let event = try? decoder.decode(ClipboardDeletionEvent.self, from: data) else {
                    continue
                }
                ids.insert(event.clipboardEventID)
            }
        }

        return ids
    }

    private func ledgerURL(for date: Date) -> URL {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        let day = formatter.string(from: date)
        return archiveRoot
            .appendingPathComponent("deletion-ledger")
            .appendingPathComponent("\(day)_deletions.ndjson")
    }
}

