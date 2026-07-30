import Foundation

/// The single suppression gate for the clipboard archive (expansion
/// contract 6).
///
/// An event is "suppressed" — hidden from every read surface — when either:
/// 1. its id has a record in the deletion ledger, or
/// 2. its stored `privacyLabel` is `.doNotIndex` (the tombstone label written
///    by redaction and pruning).
///
/// Every read path (reader, searcher, derived-index rebuild, pruner candidate
/// selection, and any future read surface) must route through this helper so
/// the definition of "visible" cannot drift between surfaces. No third
/// suppression mechanism may be added.
public struct ClipboardSuppression: Sendable {
    public var archiveRoot: URL

    public init(archiveRoot: URL) {
        self.archiveRoot = archiveRoot
    }

    /// Resolves the deletion ledger once and returns a point-in-time view.
    /// Read loops should take one snapshot up front and test every decoded
    /// event against it instead of re-reading the ledger per event.
    public func snapshot() throws -> Snapshot {
        Snapshot(deletedIDs: try ClipboardDeletionLedger(archiveRoot: archiveRoot).deletedIDs())
    }

    /// Convenience for single-event checks outside a read loop.
    public func isSuppressed(_ event: StoredClipboardEvent) throws -> Bool {
        try snapshot().isSuppressed(event)
    }

    /// A point-in-time suppression view backed by one ledger read.
    public struct Snapshot: Sendable {
        public let deletedIDs: Set<String>

        public init(deletedIDs: Set<String>) {
            self.deletedIDs = deletedIDs
        }

        public func isSuppressed(_ event: StoredClipboardEvent) -> Bool {
            event.privacyLabel == .doNotIndex || deletedIDs.contains(event.id)
        }
    }
}
