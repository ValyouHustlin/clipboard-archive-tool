import Foundation

public enum ClipboardIndexUpdateStatus: Equatable, Sendable {
    case notConfigured
    case updated
    case failed
    /// The event is index-excluded (`.restricted` label or manual
    /// sensitivity override): the upsert path deleted-instead-of-inserted,
    /// so the event is stored and visible but never searchable.
    case excluded
    /// The index was missing or unusable, so a rebuild is running in the
    /// background and will pick this event up from the archive. The event
    /// IS stored; only its searchability is late.
    case deferred
}

public enum ClipboardIngestResult: Equatable, Sendable {
    case stored(StoredClipboardEvent, indexUpdate: ClipboardIndexUpdateStatus)
    case blocked(reason: String)
}

public struct ClipboardIngestor: Sendable {
    public var filter: ClipboardPrivacyFilter
    public var archiveWriter: ClipboardArchiveWriter
    public var derivedIndex: ClipboardDerivedIndex?
    /// Operational sink, passed explicitly by the surface that owns the
    /// resolution. Nil means silent: a library caller (and every test) logs
    /// nothing until a surface hands it a destination.
    public var operationalLog: ClipboardOperationalLog?
    /// Image size cap (Slice 6, contract 7): oversized image payloads
    /// become a visible blocked event BEFORE any body write or hash.
    public var richImageMaxBytes: Int

    public init(
        filter: ClipboardPrivacyFilter = ClipboardPrivacyFilter(),
        archiveWriter: ClipboardArchiveWriter,
        derivedIndex: ClipboardDerivedIndex? = nil,
        operationalLog: ClipboardOperationalLog? = nil,
        richImageMaxBytes: Int = ClipboardSettings.defaultRichImageMaxBytes
    ) {
        self.filter = filter
        // The writer records its own append repairs, so it needs the same
        // destination this ingestor was given; a writer that already has one
        // keeps it.
        var writer = archiveWriter
        if writer.operationalLog == nil {
            writer.operationalLog = operationalLog
        }
        self.archiveWriter = writer
        self.derivedIndex = derivedIndex
        self.operationalLog = operationalLog
        self.richImageMaxBytes = richImageMaxBytes
    }

    @discardableResult
    public func ingest(_ capture: ClipboardCapture) throws -> ClipboardIngestResult {
        let start = Date()
        let usage = ClipboardUsageLog(archiveRoot: archiveWriter.archiveRoot)
        do {
            let result = try ingestCapture(capture)
            switch result {
            case let .stored(event, status):
                operationalLog?.recoverCaptureFailure()
                usage.record(.capture, outcome: status == .excluded ? .excluded : .success, scope: .archive,
                    durationMs: Date().timeIntervalSince(start) * 1000, bytes: event.byteCount)
                if status == .failed { usage.record(.error, outcome: .failed, scope: .index) }
            case .blocked:
                usage.record(.blocked, scope: .archive, durationMs: Date().timeIntervalSince(start) * 1000)
            }
            return result
        } catch {
            usage.record(.error, outcome: .failed, scope: .archive, durationMs: Date().timeIntervalSince(start) * 1000)
            // The reason CLASS only: the classifier reduces the error to a
            // closed set, and the row carries its errno. No message, no
            // path, no content — the error object never leaves this line.
            operationalLog?.record(
                .captureFailed,
                errno: ClipboardCaptureFailure.classify(error).posixCode,
                count: 1
            )
            // An append that could not land says WHICH errno stopped it,
            // which separates "the volume is full" from "the archive moved".
            if let appendError = error as? ClipboardArchiveAppendError {
                operationalLog?.record(.archiveAppendFailed, errno: appendError.errnoValue, count: 1)
            }
            throw error
        }
    }

    private func ingestCapture(_ capture: ClipboardCapture) throws -> ClipboardIngestResult {
        switch filter.evaluate(capture) {
        case let .allow(flags):
            // Image size cap (Slice 6): AFTER filter-allow, BEFORE any
            // write, hash, or decode — only `data.count` is consulted.
            if let capReason = imageCapBlockReason(for: capture) {
                try archiveWriter.archiveBlockedCapture(capture, reason: capReason)
                return .blocked(reason: capReason)
            }
            // Manual-sensitivity pre-check (Slice 5): a re-copy of content
            // whose hash carries the "restricted" annotation override must
            // skip indexing WITHOUT rewriting any archive line. One
            // stat-validated annotations-cache read per accepted capture.
            // Rich captures key on their per-kind canonical hash (Slice 6).
            let contentHash = ClipboardArchiveWriter.contentHash(for: capture)
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
                    body: ClipboardDerivedIndex.indexBody(for: event, plainContent: capture.content),
                    sensitivityOverride: sensitivityOverride
                )
            )

        case let .allowStoreNoIndex(flags, ruleBundleID):
            // Per-app store-no-index rule: stored with the .restricted
            // label so EVERY index writer (this upsert, rebuilds, older
            // builds' readers via the label itself) keeps it unsearchable.
            // The image cap applies identically — an indexing rule never
            // weakens the size cap (Slice 6).
            _ = ruleBundleID
            if let capReason = imageCapBlockReason(for: capture) {
                try archiveWriter.archiveBlockedCapture(capture, reason: capReason)
                return .blocked(reason: capReason)
            }
            var event = try archiveWriter.archiveAllowedCapture(
                capture,
                privacyLabel: .restricted,
                sensitivityFlags: Array(Set(flags + ["app-rule-no-index"]))
            )
            event.sensitivityFlags = event.sensitivityFlags.sorted()
            return .stored(
                event,
                indexUpdate: updateIndex(
                    event: event,
                    body: ClipboardDerivedIndex.indexBody(for: event, plainContent: capture.content),
                    sensitivityOverride: nil
                )
            )

        case let .block(reason):
            try archiveWriter.archiveBlockedCapture(capture, reason: reason)
            return .blocked(reason: reason)
        }
    }

    /// Non-nil when the capture is an image whose bytes exceed the cap.
    /// Reason shape: `image_exceeds_size_cap:<n>b:limit:<cap>b` — the menu
    /// status wording keys off the prefix.
    private func imageCapBlockReason(for capture: ClipboardCapture) -> String? {
        guard case let .image(data, _, _, _) = capture.rich,
              data.count > richImageMaxBytes else {
            return nil
        }
        return "image_exceeds_size_cap:\(data.count)b:limit:\(richImageMaxBytes)b"
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
            let applied = try derivedIndex.upsert(
                event: event,
                body: body,
                sensitivityOverride: sensitivityOverride
            )
            guard applied else {
                return .deferred
            }
            operationalLog?.recoverIndexUpsertFailure()
            return excluded ? .excluded : .updated
        } catch {
            // The event IS stored; only its searchability failed. The row
            // says so without naming the event, the query or the path.
            operationalLog?.record(.indexUpsertFailed, count: 1)
            return .failed
        }
    }
}
