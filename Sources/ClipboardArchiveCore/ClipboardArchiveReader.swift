import Foundation

public struct ClipboardArchiveReader: Sendable {
    public var archiveRoot: URL

    public init(archiveRoot: URL) {
        self.archiveRoot = archiveRoot
    }

    public func recentItems(since: Date, limit: Int) throws -> [StoredClipboardEvent] {
        let deleted = try ClipboardDeletionLedger(archiveRoot: archiveRoot).deletedIDs()
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        var items: [StoredClipboardEvent] = []

        for fileURL in try eventFiles().reversed() {
            let lines = try String(contentsOf: fileURL).split(separator: "\n", omittingEmptySubsequences: true)
            for line in lines.reversed() {
                guard let data = String(line).data(using: .utf8),
                      let event = try? decoder.decode(StoredClipboardEvent.self, from: data),
                      event.capturedAt >= since,
                      !deleted.contains(event.id) else {
                    continue
                }
                items.append(event)
                if items.count >= limit {
                    return items
                }
            }
        }

        return items
    }

    public func content(for event: StoredClipboardEvent) throws -> String {
        if let contentInline = event.contentInline {
            return contentInline
        }
        guard let rawContentPath = event.rawContentPath else {
            return event.contentPreview
        }
        return try String(contentsOf: archiveRoot.appendingPathComponent(rawContentPath))
    }

    public func eventFiles() throws -> [URL] {
        let rawRoot = archiveRoot.appendingPathComponent("raw")
        guard FileManager.default.fileExists(atPath: rawRoot.path) else {
            return []
        }

        let urls = FileManager.default.enumerator(
            at: rawRoot,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        )?.compactMap { $0 as? URL } ?? []

        return try urls
            .filter { url in
                let values = try url.resourceValues(forKeys: [.isRegularFileKey])
                return values.isRegularFile == true && url.lastPathComponent.hasSuffix("_clipboard-events.ndjson")
            }
            .sorted { $0.path < $1.path }
    }
}

