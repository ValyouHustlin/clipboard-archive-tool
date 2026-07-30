import Foundation

/// Selection criteria for one bulk operation (Slice 5). All fields combine
/// with AND; a criteria value that is nil does not constrain the match.
public struct ClipboardBulkCriteria: Equatable, Sendable {
    public enum Sensitivity: String, Equatable, Sendable {
        /// Any sensitivity signal: non-empty stored sensitivity flags, a
        /// stored `.restricted` label, or a manual "restricted" override.
        case anyFlagged = "any-flagged"
        /// Only content carrying the manual "restricted" annotation
        /// override.
        case manualRestricted = "manual-restricted"
    }

    /// Explicit occurrence ids (History multi-select, expiry sweep).
    public var eventIDs: Set<String>?
    /// Inclusive capture-time bounds.
    public var since: Date?
    public var until: Date?
    /// Case-insensitive bundle identifier match.
    public var bundleID: String?
    /// Exact source app display-name match.
    public var sourceAppName: String?
    /// Raw content-type string match (tolerance-friendly).
    public var contentType: String?
    public var sensitivity: Sensitivity?
    /// Contract 5: pinned content is exempt by default; true is the
    /// explicit, separately-confirmed override.
    public var includePinned: Bool

    public init(
        eventIDs: Set<String>? = nil,
        since: Date? = nil,
        until: Date? = nil,
        bundleID: String? = nil,
        sourceAppName: String? = nil,
        contentType: String? = nil,
        sensitivity: Sensitivity? = nil,
        includePinned: Bool = false
    ) {
        self.eventIDs = eventIDs
        self.since = since
        self.until = until
        self.bundleID = bundleID
        self.sourceAppName = sourceAppName
        self.contentType = contentType
        self.sensitivity = sensitivity
        self.includePinned = includePinned
    }

    /// True when no criterion constrains the match (a full-archive delete —
    /// callers should refuse or demand extra confirmation).
    public var isEmpty: Bool {
        activeCriterionKeys.isEmpty
    }

    /// Sorted names of the active criteria; the ledger reason is derived
    /// from these so every bulk deletion is attributable to what selected
    /// it. `includePinned` is a modifier, not a criterion.
    public var activeCriterionKeys: [String] {
        var keys: [String] = []
        if eventIDs != nil { keys.append("eventIDs") }
        if since != nil { keys.append("since") }
        if until != nil { keys.append("until") }
        if bundleID != nil { keys.append("bundleID") }
        if sourceAppName != nil { keys.append("sourceAppName") }
        if contentType != nil { keys.append("contentType") }
        if sensitivity != nil { keys.append("sensitivity") }
        return keys.sorted()
    }

    /// Machine-readable ledger reason (contract 6: `bulk-<criterion>`).
    public var ledgerReason: String {
        "bulk-" + activeCriterionKeys.joined(separator: "+")
    }
}

/// Result of one bulk preview or execution. Preview (dry run) and execute
/// report the SAME numbers by construction: both flow through one
/// `run(_:dryRun:)` path into the shared pruner core.
public struct ClipboardBulkResult: Codable, Equatable, Sendable {
    public var matchedEvents: Int
    public var reclaimedBytes: Int64
    public var deletedBodyFiles: Int
    public var changedFiles: Int
    public var exemptedPinnedEvents: Int
    public var removedAnnotationHashes: Int
    public var dryRun: Bool
    public var reason: String

    public init(
        matchedEvents: Int,
        reclaimedBytes: Int64,
        deletedBodyFiles: Int,
        changedFiles: Int,
        exemptedPinnedEvents: Int,
        removedAnnotationHashes: Int,
        dryRun: Bool,
        reason: String
    ) {
        self.matchedEvents = matchedEvents
        self.reclaimedBytes = reclaimedBytes
        self.deletedBodyFiles = deletedBodyFiles
        self.changedFiles = changedFiles
        self.exemptedPinnedEvents = exemptedPinnedEvents
        self.removedAnnotationHashes = removedAnnotationHashes
        self.dryRun = dryRun
        self.reason = reason
    }
}

/// Bulk management engine (Slice 5, contract 6): composes the ONE
/// destructive pruner core — it never invents a second deletion path.
/// PARITY BY CONSTRUCTION: `preview` and `execute` call the same private
/// `run(_:dryRun:)`, which compiles ONE predicate and hands it to the
/// extended pruner core. No selection logic exists outside this path.
public struct ClipboardBulkEngine: Sendable {
    public var archiveRoot: URL
    public var indexURL: URL

    public init(
        archiveRoot: URL,
        indexURL: URL = ClipboardDefaults.indexURL()
    ) {
        self.archiveRoot = archiveRoot
        self.indexURL = indexURL
    }

    /// Truthful dry-run preview: same code path, no writes.
    public func preview(
        _ criteria: ClipboardBulkCriteria,
        reason: String? = nil
    ) throws -> ClipboardBulkResult {
        try run(criteria, dryRun: true, reasonOverride: reason)
    }

    /// Executes the bulk deletion. NOT undoable — callers must have shown
    /// the dry-run preview first and named the irreversibility.
    @discardableResult
    public func execute(
        _ criteria: ClipboardBulkCriteria,
        reason: String? = nil
    ) throws -> ClipboardBulkResult {
        try run(criteria, dryRun: false, reasonOverride: reason)
    }

    private func run(
        _ criteria: ClipboardBulkCriteria,
        dryRun: Bool,
        reasonOverride: String?
    ) throws -> ClipboardBulkResult {
        let annotations = ClipboardAnnotationsStore(archiveRoot: archiveRoot)
        let exemptContentHashes = criteria.includePinned
            ? Set<String>()
            : annotations.pinnedContentHashes()
        // Sensitivity criteria resolve annotation overrides ONCE per run so
        // the predicate stays a pure function during the scan.
        let restrictedHashes: Set<String>
        if criteria.sensitivity != nil {
            restrictedHashes = annotations.restrictedContentHashes()
        } else {
            restrictedHashes = []
        }

        let dayRange: ClosedRange<Date>?
        if criteria.since != nil || criteria.until != nil {
            dayRange = (criteria.since ?? .distantPast)...(criteria.until ?? .distantFuture)
        } else {
            dayRange = nil
        }

        let reason = reasonOverride ?? criteria.ledgerReason
        let outcome = try ClipboardArchivePruner(archiveRoot: archiveRoot, indexURL: indexURL)
            .pruneCore(
                dryRun: dryRun,
                reason: reason,
                exemptContentHashes: exemptContentHashes,
                restrictToDayRange: dayRange
            ) { event in
                Self.matches(event, criteria: criteria, restrictedHashes: restrictedHashes)
            }

        return ClipboardBulkResult(
            matchedEvents: outcome.result.prunedEvents,
            reclaimedBytes: outcome.result.reclaimedBytes,
            deletedBodyFiles: outcome.result.deletedBodyFiles,
            changedFiles: outcome.result.changedFiles,
            exemptedPinnedEvents: outcome.result.exemptedPinnedEvents,
            removedAnnotationHashes: outcome.removedAnnotationHashes,
            dryRun: dryRun,
            reason: reason
        )
    }

    /// The one compiled predicate. All criteria AND together.
    private static func matches(
        _ event: StoredClipboardEvent,
        criteria: ClipboardBulkCriteria,
        restrictedHashes: Set<String>
    ) -> Bool {
        if let eventIDs = criteria.eventIDs, !eventIDs.contains(event.id) {
            return false
        }
        if let since = criteria.since, event.capturedAt < since {
            return false
        }
        if let until = criteria.until, event.capturedAt > until {
            return false
        }
        if let bundleID = criteria.bundleID,
           event.sourceApp.bundleIdentifier?.lowercased() != bundleID.lowercased() {
            return false
        }
        if let sourceAppName = criteria.sourceAppName,
           event.sourceApp.name != sourceAppName {
            return false
        }
        if let contentType = criteria.contentType,
           event.contentType.rawValue != contentType {
            return false
        }
        if let sensitivity = criteria.sensitivity {
            let manuallyRestricted = restrictedHashes.contains(event.contentHash)
            switch sensitivity {
            case .anyFlagged:
                guard !event.sensitivityFlags.isEmpty
                    || event.privacyLabel == .restricted
                    || manuallyRestricted else {
                    return false
                }
            case .manualRestricted:
                guard manuallyRestricted else {
                    return false
                }
            }
        }
        return true
    }
}
