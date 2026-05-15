import Foundation

public struct ClipboardSearchOptions: Sendable {
    public var query: String
    public var since: Date?
    public var until: Date?
    public var limit: Int

    public init(query: String, since: Date? = nil, until: Date? = nil, limit: Int = 25) {
        self.query = query
        self.since = since
        self.until = until
        self.limit = limit
    }
}

public struct ClipboardSearchResult: Equatable, Sendable {
    public var event: StoredClipboardEvent
    public var matchedInBody: Bool
    public var snippet: String

    public init(event: StoredClipboardEvent, matchedInBody: Bool, snippet: String) {
        self.event = event
        self.matchedInBody = matchedInBody
        self.snippet = snippet
    }
}

public struct ClipboardArchiveSearcher: Sendable {
    public var archiveRoot: URL

    public init(archiveRoot: URL) {
        self.archiveRoot = archiveRoot
    }

    public func search(_ options: ClipboardSearchOptions) throws -> [ClipboardSearchResult] {
        let normalizedQuery = options.query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalizedQuery.isEmpty else {
            return []
        }

        let deleted = try ClipboardDeletionLedger(archiveRoot: archiveRoot).deletedIDs()
        var results: [ClipboardSearchResult] = []
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        for fileURL in try ClipboardArchiveReader(archiveRoot: archiveRoot).eventFiles().reversed() {
            let lines = try String(contentsOf: fileURL).split(separator: "\n", omittingEmptySubsequences: true)
            for line in lines.reversed() {
                guard let data = String(line).data(using: .utf8),
                      let event = try? decoder.decode(StoredClipboardEvent.self, from: data),
                      isWithinDateWindow(event.capturedAt, options: options),
                      !deleted.contains(event.id) else {
                    continue
                }

                if let match = match(event: event, query: normalizedQuery) {
                    results.append(match)
                    if results.count >= options.limit {
                        return results
                    }
                }
            }
        }

        return results
    }

    private func isWithinDateWindow(_ date: Date, options: ClipboardSearchOptions) -> Bool {
        if let since = options.since, date < since {
            return false
        }
        if let until = options.until, date > until {
            return false
        }
        return true
    }

    private func match(event: StoredClipboardEvent, query: String) -> ClipboardSearchResult? {
        let searchableHeader = [
            event.contentPreview,
            event.contentInline ?? "",
            event.sourceApp.name,
            event.sourceApp.bundleIdentifier ?? "",
            event.contentType.rawValue,
            event.pasteboardTypes.joined(separator: " ")
        ].joined(separator: "\n")

        if searchableHeader.lowercased().contains(query) {
            return ClipboardSearchResult(
                event: event,
                matchedInBody: false,
                snippet: snippet(from: searchableHeader, query: query)
            )
        }

        guard let rawContentPath = event.rawContentPath else {
            return nil
        }

        let bodyURL = archiveRoot.appendingPathComponent(rawContentPath)
        guard let body = try? String(contentsOf: bodyURL),
              body.lowercased().contains(query) else {
            return nil
        }

        return ClipboardSearchResult(
            event: event,
            matchedInBody: true,
            snippet: snippet(from: body, query: query)
        )
    }

    private func snippet(from text: String, query: String) -> String {
        let lower = text.lowercased()
        guard let range = lower.range(of: query) else {
            return String(text.prefix(240))
        }

        let start = lower.index(range.lowerBound, offsetBy: -80, limitedBy: lower.startIndex) ?? lower.startIndex
        let end = lower.index(range.upperBound, offsetBy: 160, limitedBy: lower.endIndex) ?? lower.endIndex
        return String(text[start..<end])
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\t", with: " ")
    }
}
