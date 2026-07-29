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
        let bodyURL = try ClipboardArchivePath.containedURL(
            relativePath: rawContentPath,
            archiveRoot: archiveRoot
        )
        return try String(contentsOf: bodyURL)
    }

    public func eventFiles() throws -> [URL] {
        let rawRoot = archiveRoot.appendingPathComponent("raw")
        guard FileManager.default.fileExists(atPath: rawRoot.path) else {
            return []
        }

        let urls = FileManager.default.enumerator(
            at: rawRoot,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles]
        )?.compactMap { $0 as? URL } ?? []

        return try urls
            .filter { url in
                let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
                guard values.isRegularFile == true,
                      values.isSymbolicLink != true,
                      url.lastPathComponent.hasSuffix("_clipboard-events.ndjson") else {
                    return false
                }
                let rootPath = archiveRoot.standardizedFileURL.path
                guard url.standardizedFileURL.path.hasPrefix(rootPath + "/") else {
                    return false
                }
                let relativePath = String(url.standardizedFileURL.path.dropFirst(rootPath.count + 1))
                return (try? ClipboardArchivePath.containedURL(
                    relativePath: relativePath,
                    archiveRoot: archiveRoot
                )) != nil
            }
            .sorted { $0.path < $1.path }
    }
}
