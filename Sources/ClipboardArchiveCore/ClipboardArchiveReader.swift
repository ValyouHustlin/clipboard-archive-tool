import Foundation

public struct ClipboardArchiveReader: Sendable {
    public var archiveRoot: URL

    public init(archiveRoot: URL) {
        self.archiveRoot = archiveRoot
    }

    public func recentItems(since: Date, limit: Int) throws -> [StoredClipboardEvent] {
        let suppression = try ClipboardSuppression(archiveRoot: archiveRoot).snapshot()
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        var items: [StoredClipboardEvent] = []

        for fileURL in try eventFiles().reversed() {
            let lines = try String(contentsOf: fileURL).split(separator: "\n", omittingEmptySubsequences: true)
            for line in lines.reversed() {
                guard let data = String(line).data(using: .utf8),
                      let event = try? decoder.decode(StoredClipboardEvent.self, from: data),
                      event.capturedAt >= since,
                      !suppression.isSuppressed(event) else {
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

    /// Fetches one stored event by occurrence id without scanning the
    /// archive. Event ids embed their UTC capture day
    /// (`clip_yyyyMMdd'T'HHmmss'Z'_…`, same UTC formatter family as the day
    /// file names), so the lookup decodes exactly ONE day file. Returns nil
    /// for malformed or traversal-shaped ids, a missing day file, an id not
    /// present in its day file, or a suppressed event (deletion ledger or
    /// doNotIndex label) — a stale search index must never resurrect
    /// deleted content. This method NEVER falls back to a full archive scan.
    public func event(withID id: String) throws -> StoredClipboardEvent? {
        // Shape validation: "clip_" prefix + 8 ASCII digits (UTC yyyyMMdd)
        // at byte offsets 5..<13. Anything else — including ids crafted to
        // look like paths — is rejected before any filesystem access.
        guard id.hasPrefix("clip_") else {
            return nil
        }
        let bytes = Array(id.utf8)
        guard bytes.count >= 13 else {
            return nil
        }
        let digits = bytes[5..<13]
        guard digits.allSatisfy({ $0 >= UInt8(ascii: "0") && $0 <= UInt8(ascii: "9") }) else {
            return nil
        }
        let day = String(decoding: digits, as: UTF8.self)
        let year = String(day.prefix(4))
        let month = String(day.dropFirst(4).prefix(2))
        let dayOfMonth = String(day.suffix(2))
        let relativePath = "raw/\(year)/\(month)/\(year)-\(month)-\(dayOfMonth)_clipboard-events.ndjson"
        guard let fileURL = try? ClipboardArchivePath.containedURL(
            relativePath: relativePath,
            archiveRoot: archiveRoot
        ), FileManager.default.fileExists(atPath: fileURL.path) else {
            return nil
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let suppression = try ClipboardSuppression(archiveRoot: archiveRoot).snapshot()
        for line in try String(contentsOf: fileURL)
            .split(separator: "\n", omittingEmptySubsequences: true) {
            guard let data = String(line).data(using: .utf8),
                  let event = try? decoder.decode(StoredClipboardEvent.self, from: data),
                  event.id == id else {
                continue
            }
            return suppression.isSuppressed(event) ? nil : event
        }
        return nil
    }

    /// Recent blocked-event audit records (no content was ever stored for
    /// these), newest first. Powers the dashboard's "Recent Blocked Items"
    /// section (Slice 5).
    public func recentBlockedEvents(since: Date, limit: Int) throws -> [BlockedClipboardEvent] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        var items: [BlockedClipboardEvent] = []

        for fileURL in try eventFiles().reversed() {
            let lines = try String(contentsOf: fileURL).split(separator: "\n", omittingEmptySubsequences: true)
            for line in lines.reversed() {
                guard let data = String(line).data(using: .utf8),
                      let blocked = try? decoder.decode(BlockedClipboardEvent.self, from: data),
                      blocked.eventType == "blocked_sensitive_clipboard_item",
                      blocked.capturedAt >= since else {
                    continue
                }
                items.append(blocked)
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
