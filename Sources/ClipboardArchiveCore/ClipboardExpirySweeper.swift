import Foundation

public struct ClipboardExpirySweepResult: Codable, Equatable, Sendable {
    /// Content hashes whose expiry was due and processed this sweep.
    public var sweptContentHashes: Int
    /// Occurrences deleted across all swept hashes.
    public var deletedEvents: Int
    /// Bytes reclaimed (same truthful accounting as the bulk engine).
    public var reclaimedBytes: Int64

    public init(sweptContentHashes: Int = 0, deletedEvents: Int = 0, reclaimedBytes: Int64 = 0) {
        self.sweptContentHashes = sweptContentHashes
        self.deletedEvents = deletedEvents
        self.reclaimedBytes = reclaimedBytes
    }
}

/// Expiring sensitive clips (Slice 5). Enforcement points are app launch,
/// a 30-minute timer, and lazy checks when a read surface opens — NEVER the
/// capture poll, and NEVER read-time hiding (that would be a third
/// suppression mechanism; contract 6 forbids it). Between enforcement
/// points an expired clip can remain briefly visible; Settings copy states
/// this honestly.
public struct ClipboardExpirySweeper: Sendable {
    public var archiveRoot: URL
    public var indexURL: URL

    public init(
        archiveRoot: URL,
        indexURL: URL = ClipboardDefaults.indexURL()
    ) {
        self.archiveRoot = archiveRoot
        self.indexURL = indexURL
    }

    /// The earliest pending expiry. ONE stat-validated annotations-cache
    /// read; zero archive IO — cheap enough for every timer tick.
    public func nextDue() -> Date? {
        ClipboardAnnotationsStore(archiveRoot: archiveRoot).earliestExpiry()
    }

    /// Sweeps every due expiry. Per due content hash: resolve live
    /// occurrence ids (suppression-filtered index query with a reader-scan
    /// fallback), bulk-execute those ids with `includePinned: true` (expiry
    /// is the user's explicit instruction — stated when setting expiry on a
    /// pinned clip) and ledger reason `expired-sensitive`, then clear the
    /// annotation so the expiry never re-fires.
    @discardableResult
    public func sweepIfDue(now: Date = Date()) throws -> ClipboardExpirySweepResult {
        guard let due = nextDue(), due <= now else {
            return ClipboardExpirySweepResult()
        }

        let annotations = ClipboardAnnotationsStore(archiveRoot: archiveRoot)
        let resolver = ClipboardOccurrenceResolver(archiveRoot: archiveRoot, indexURL: indexURL)
        let engine = ClipboardBulkEngine(archiveRoot: archiveRoot, indexURL: indexURL)
        var result = ClipboardExpirySweepResult()

        for entry in annotations.entriesWithExpiry() where entry.expiresAt <= now {
            let occurrenceIDs = try resolver.liveOccurrenceIDs(contentHash: entry.contentHash)
            if !occurrenceIDs.isEmpty {
                let executed = try engine.execute(
                    ClipboardBulkCriteria(
                        eventIDs: Set(occurrenceIDs),
                        includePinned: true
                    ),
                    reason: "expired-sensitive"
                )
                result.deletedEvents += executed.matchedEvents
                result.reclaimedBytes += executed.reclaimedBytes
            }
            // The content is gone (or already was): drop the whole
            // annotation record so pins/tags/expiry never dangle. Read-only
            // newer-format stores throw; the sweep surfaces that instead of
            // looping forever on the same due entry.
            try annotations.removeContentReference(contentHash: entry.contentHash)
            result.sweptContentHashes += 1
        }
        return result
    }
}
