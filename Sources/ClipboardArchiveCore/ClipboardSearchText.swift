import Foundation

/// Literal, case-insensitive substrings. Whitespace-separated terms combine
/// with AND; punctuation and search operators are ordinary text.
public enum ClipboardSearchText {
    public static func terms(_ query: String) -> [String] {
        query.lowercased().split(whereSeparator: { $0.isWhitespace }).map(String.init)
    }

    public static func matches(_ text: String, terms: [String]) -> Bool {
        let normalized = text.lowercased()
        return terms.allSatisfy { normalized.contains($0) }
    }

    public static func text(for event: StoredClipboardEvent, body: String) -> String {
        [body, event.contentPreview, event.sourceApp.name, event.contentType.rawValue]
            .joined(separator: " ")
    }

    /// Full searchable text for the reader-backed window. Restricted items
    /// remain browsable, but no body or metadata is cached for their search.
    /// Duplicate archive IDs are tolerated without trapping.
    public static func windowText(events: [StoredClipboardEvent], reader: ClipboardArchiveReader) -> [String: String] {
        let restricted = ClipboardAnnotationsStore(archiveRoot: reader.archiveRoot).restrictedContentHashes()
        var result: [String: String] = [:]
        for event in events {
            guard !ClipboardSuppression.isIndexExcluded(event,
                sensitivityOverride: restricted.contains(event.contentHash) ? "restricted" : nil) else { continue }
            let body = (try? reader.content(for: event)) ?? event.contentPreview
            result[event.id] = text(for: event,
                body: ClipboardDerivedIndex.indexBody(for: event, plainContent: body))
        }
        return result
    }

    public static func windowMatches(_ event: StoredClipboardEvent, terms: [String], text: [String: String]) -> Bool {
        terms.isEmpty || text[event.id].map { matches($0, terms: terms) } == true
    }

    public static func snippet(_ body: String, terms: [String]) -> String {
        guard let term = terms.first,
              let range = body.range(of: term, options: [.caseInsensitive]) else {
            return String(body.prefix(240))
        }
        let start = body.index(range.lowerBound, offsetBy: -60, limitedBy: body.startIndex) ?? body.startIndex
        return (start == body.startIndex ? "" : "… ") + String(body[start...].prefix(240))
    }
}
