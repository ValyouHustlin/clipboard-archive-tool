import Foundation

public enum ClipboardIndexUpdateStatus: Equatable, Sendable {
    case notConfigured
    case updated
    case failed
    /// The event is index-excluded (`.restricted` label or manual
    /// sensitivity override): the upsert path deleted-instead-of-inserted,
    /// so the event is stored and visible but never searchable.
    case excluded
}

public enum ClipboardIngestResult: Equatable, Sendable {
    case stored(StoredClipboardEvent, indexUpdate: ClipboardIndexUpdateStatus)
    case blocked(reason: String)
}

public struct ClipboardIngestor: Sendable {
    public var filter: ClipboardPrivacyFilter
    public var archiveWriter: ClipboardArchiveWriter
    public var derivedIndex: ClipboardDerivedIndex?

    public init(
        filter: ClipboardPrivacyFilter = ClipboardPrivacyFilter(),
        archiveWriter: ClipboardArchiveWriter,
        derivedIndex: ClipboardDerivedIndex? = nil
    ) {
        self.filter = filter
        self.archiveWriter = archiveWriter
        self.derivedIndex = derivedIndex
    }

    @discardableResult
    public func ingest(_ capture: ClipboardCapture) throws -> ClipboardIngestResult {
        switch filter.evaluate(capture) {
        case let .allow(flags):
            // Manual-sensitivity pre-check (Slice 5): a re-copy of content
            // whose hash carries the "restricted" annotation override must
            // skip indexing WITHOUT rewriting any archive line. One
            // stat-validated annotations-cache read per accepted capture.
            let contentHash = ClipboardArchiveWriter.contentHash(for: capture.content)
            let sensitivityOverride = ClipboardAnnotationsStore(
                archiveRoot: archiveWriter.archiveRoot
            ).annotation(for: contentHash)?.sensitivityOverride
            let manuallyRestricted = sensitivityOverride == "restricted"
            var event = try archiveWriter.archiveAllowedCapture(
                capture,
                sensitivityFlags: manuallyRestricted
                    ? Array(Set(flags + ["manual-restricted"]))
                    : flags
            )
            event.sensitivityFlags = event.sensitivityFlags.sorted()
            return .stored(
                event,
                indexUpdate: updateIndex(
                    event: event,
                    body: capture.content,
                    sensitivityOverride: sensitivityOverride
                )
            )

        case let .allowStoreNoIndex(flags, ruleBundleID):
            // Per-app store-no-index rule: stored with the .restricted
            // label so EVERY index writer (this upsert, rebuilds, older
            // builds' readers via the label itself) keeps it unsearchable.
            _ = ruleBundleID
            var event = try archiveWriter.archiveAllowedCapture(
                capture,
                privacyLabel: .restricted,
                sensitivityFlags: Array(Set(flags + ["app-rule-no-index"]))
            )
            event.sensitivityFlags = event.sensitivityFlags.sorted()
            return .stored(
                event,
                indexUpdate: updateIndex(event: event, body: capture.content, sensitivityOverride: nil)
            )

        case let .block(reason):
            try archiveWriter.archiveBlockedCapture(capture, reason: reason)
            return .blocked(reason: reason)
        }
    }

    private func updateIndex(
        event: StoredClipboardEvent,
        body: String,
        sensitivityOverride: String?
    ) -> ClipboardIndexUpdateStatus {
        guard let derivedIndex else {
            return .notConfigured
        }
        let excluded = ClipboardSuppression.isIndexExcluded(
            event,
            sensitivityOverride: sensitivityOverride
        )
        do {
            try derivedIndex.upsert(event: event, body: body, sensitivityOverride: sensitivityOverride)
            return excluded ? .excluded : .updated
        } catch {
            return .failed
        }
    }
}
