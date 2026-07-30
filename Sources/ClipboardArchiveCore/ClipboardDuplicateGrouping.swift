import Foundation

/// Anything the history window can group by content identity (expansion
/// contract 2): both the in-memory `StoredClipboardEvent` path (This Window)
/// and the derived-index result path (All History).
public protocol ClipboardDuplicateGroupable {
    var duplicateContentHash: String { get }
    var duplicateCapturedAt: Date { get }
}

extension StoredClipboardEvent: ClipboardDuplicateGroupable {
    public var duplicateContentHash: String { contentHash }
    public var duplicateCapturedAt: Date { capturedAt }
}

extension ClipboardIndexSearchResult: ClipboardDuplicateGroupable {
    public var duplicateContentHash: String { contentHash }
    public var duplicateCapturedAt: Date { capturedAt }
}

/// Two or more occurrences of the same content hash.
public struct ClipboardDuplicateGroup<Item: ClipboardDuplicateGroupable> {
    public var contentHash: String
    /// Newest first.
    public var occurrences: [Item]
    public var firstCapturedAt: Date
    public var lastCapturedAt: Date

    public var count: Int {
        occurrences.count
    }

    /// The newest occurrence — the representative a collapsed group row
    /// shows and the one a group copy commits.
    public var newest: Item {
        occurrences[0]
    }
}

public enum ClipboardHistoryGroupedRow<Item: ClipboardDuplicateGroupable> {
    case single(Item)
    case group(ClipboardDuplicateGroup<Item>)
}

/// Pure grouping engine for duplicate collapsing. Grouping is PRESENTATION:
/// it runs after the existing filter predicate (type filter + query +
/// collection filter) so counts are honest about what survived filtering.
public enum ClipboardDuplicateGrouping {
    /// Groups an already-filtered item list by content hash.
    ///
    /// - Row order follows the input order of each hash's FIRST appearance
    ///   (inputs are newest-first, so groups sort by their newest copy).
    /// - Items with an empty content hash (rows indexed by an older binary
    ///   before the hash column existed) never group.
    /// - A hash with exactly one occurrence stays a plain single row.
    /// Slot in first-appearance order: a standalone item (empty hash) or a
    /// hash bucket reference.
    private enum GroupingSlot<Item: ClipboardDuplicateGroupable> {
        case single(Item)
        case hash(String)
    }

    public static func rows<Item: ClipboardDuplicateGroupable>(
        grouping items: [Item]
    ) -> [ClipboardHistoryGroupedRow<Item>] {
        var slots: [GroupingSlot<Item>] = []
        var buckets: [String: [Item]] = [:]

        for item in items {
            let hash = item.duplicateContentHash
            guard !hash.isEmpty else {
                slots.append(.single(item))
                continue
            }
            if buckets[hash] == nil {
                slots.append(.hash(hash))
            }
            buckets[hash, default: []].append(item)
        }

        return slots.map { slot in
            switch slot {
            case let .single(item):
                return .single(item)
            case let .hash(hash):
                let occurrences = (buckets[hash] ?? [])
                    .sorted { $0.duplicateCapturedAt > $1.duplicateCapturedAt }
                guard occurrences.count > 1, let newest = occurrences.first else {
                    return .single(occurrences[0])
                }
                return .group(ClipboardDuplicateGroup(
                    contentHash: hash,
                    occurrences: occurrences,
                    firstCapturedAt: occurrences.map(\.duplicateCapturedAt).min()
                        ?? newest.duplicateCapturedAt,
                    lastCapturedAt: occurrences.map(\.duplicateCapturedAt).max()
                        ?? newest.duplicateCapturedAt
                ))
            }
        }
    }
}
