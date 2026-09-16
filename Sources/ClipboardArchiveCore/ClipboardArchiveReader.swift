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
            for line in try eventLines(of: fileURL).reversed() {
                guard let event = try? decoder.decode(StoredClipboardEvent.self, from: line),
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
        for line in try eventLines(of: fileURL) {
            guard let event = try? decoder.decode(StoredClipboardEvent.self, from: line),
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
            for line in try eventLines(of: fileURL).reversed() {
                guard let blocked = try? decoder.decode(BlockedClipboardEvent.self, from: line),
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

    /// Raw rich body bytes (Slice 6): the image/RTF payload or the spilled
    /// full file list. Returns nil when the event has no rich body; throws
    /// on a containment-escaping path (`ClipboardArchivePathError`) — a
    /// crafted `bodyPath` must never read outside the archive root.
    public func richBody(for event: StoredClipboardEvent) throws -> Data? {
        guard let bodyPath = event.richContent?.bodyPath else {
            return nil
        }
        let bodyURL = try ClipboardArchivePath.containedURL(
            relativePath: bodyPath,
            archiveRoot: archiveRoot
        )
        return try Data(contentsOf: bodyURL)
    }

    /// The COMPLETE file list for a file-reference event: the inline
    /// entries, or the spilled `<id>.json` body when the list was truncated
    /// (falls back to the inline first-100 if the body is unreadable).
    public func fileList(for event: StoredClipboardEvent) -> [ClipboardRichFileReference] {
        guard let rich = event.richContent, rich.kind == ClipboardRichContent.fileListKind else {
            return []
        }
        let inline = rich.files ?? []
        guard rich.filesTruncated == true else {
            return inline
        }
        guard let data = try? richBody(for: event),
              let full = try? JSONDecoder().decode([ClipboardRichFileReference].self, from: data) else {
            return inline
        }
        return full
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
        return try String.readingClipboardText(contentsOf: bodyURL)
    }

    /// One day file's NDJSON rows as raw byte slices, oldest first.
    ///
    /// The bytes are split on the newline byte instead of being decoded
    /// into a `String` first. `String(contentsOf:)` sniffs the file's
    /// encoding before it returns, which costs about 27 ms on a 280 KB day
    /// file where reading the same bytes costs well under one, and the
    /// archive is UTF-8 JSON by construction, so there is nothing for the
    /// sniffing to find. A row torn by a killed write is still a slice that
    /// fails to decode and is skipped, exactly as before.
    private func eventLines(of fileURL: URL) throws -> [Data] {
        try Data(contentsOf: fileURL)
            .split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: true)
    }

    public func eventFiles() throws -> [URL] {
        // The root is resolved ONCE: enumeration reports real paths, so an
        // unresolved root (a symlinked archive folder, or the /private/tmp
        // spelling of /tmp) would fail the containment test below and drop
        // every day file.
        let resolvedRoot = ClipboardArchivePath.resolvedRoot(archiveRoot)
        let rawRoot = resolvedRoot.appendingPathComponent("raw")
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
                let rootPath = resolvedRoot.path
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
