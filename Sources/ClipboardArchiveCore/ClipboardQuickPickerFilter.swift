import Foundation

/// Pure, AppKit-free filtering for the quick picker (unit-testable). Matching
/// semantics deliberately mirror the History window filter: lowercased
/// substring match over the preview text, source app name, and content type
/// raw value. Preview-only search is intentional for the picker; full-text
/// FTS search over archived bodies is Slice 3.
public enum ClipboardQuickPickerFilter {
    public static func filter(
        events: [StoredClipboardEvent],
        query: String
    ) -> [StoredClipboardEvent] {
        let normalizedQuery = query
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard !normalizedQuery.isEmpty else {
            return events
        }
        return events.filter { event in
            [
                event.contentPreview,
                event.sourceApp.name,
                event.contentType.rawValue
            ]
            .joined(separator: " ")
            .lowercased()
            .contains(normalizedQuery)
        }
    }
}
