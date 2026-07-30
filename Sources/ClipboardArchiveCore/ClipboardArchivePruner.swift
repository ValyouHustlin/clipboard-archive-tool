import Foundation

public struct ClipboardPruneResult: Codable, Equatable, Sendable {
    public var scannedEvents: Int
    public var prunedEvents: Int
    public var deletedBodyFiles: Int
    public var changedFiles: Int
    public var dryRun: Bool
    /// Events that matched the prune predicate but were kept because their
    /// content hash is pinned (contract 5). Dry runs report the same number
    /// the real run would, so previews stay truthful.
    public var exemptedPinnedEvents: Int

    public init(
        scannedEvents: Int,
        prunedEvents: Int,
        deletedBodyFiles: Int,
        changedFiles: Int,
        dryRun: Bool,
        exemptedPinnedEvents: Int = 0
    ) {
        self.scannedEvents = scannedEvents
        self.prunedEvents = prunedEvents
        self.deletedBodyFiles = deletedBodyFiles
        self.changedFiles = changedFiles
        self.dryRun = dryRun
        self.exemptedPinnedEvents = exemptedPinnedEvents
    }
}

public struct ClipboardRetentionEnforcementResult: Codable, Equatable, Sendable {
    /// Live (unsuppressed) events found by the enforcement scan, counted
    /// before any pruning done by this call. Includes pinned events.
    public var liveEvents: Int
    public var prunedEvents: Int
    public var deletedBodyFiles: Int
    public var changedFiles: Int
    /// Pinned live events that sat OUTSIDE the retention limit this pass
    /// (they are never counted against it and never pruned).
    public var exemptPinnedEvents: Int

    /// Live events remaining after this call (pinned included).
    public var keptEvents: Int {
        liveEvents - prunedEvents
    }

    /// Unpinned live events remaining after this call — the number that
    /// counts against the retention limit. The app's in-memory estimate must
    /// seed from THIS, not `keptEvents`, or pinned items would consume limit
    /// slots in the estimate and force needless scans.
    public var keptCountedEvents: Int {
        liveEvents - exemptPinnedEvents - prunedEvents
    }

    public init(
        liveEvents: Int,
        prunedEvents: Int,
        deletedBodyFiles: Int,
        changedFiles: Int,
        exemptPinnedEvents: Int = 0
    ) {
        self.liveEvents = liveEvents
        self.prunedEvents = prunedEvents
        self.deletedBodyFiles = deletedBodyFiles
        self.changedFiles = changedFiles
        self.exemptPinnedEvents = exemptPinnedEvents
    }
}

public struct ClipboardArchivePruner: Sendable {
    public var archiveRoot: URL
    public var indexURL: URL

    public init(
        archiveRoot: URL,
        indexURL: URL = ClipboardDefaults.indexURL()
    ) {
        self.archiveRoot = archiveRoot
        self.indexURL = indexURL
    }

    /// Pinned content is exempt from pruning by default (contract 5).
    /// `includePinned: true` is the explicit override — callers must confirm
    /// it separately in the UI; it is never the default anywhere.
    @discardableResult
    public func pruneContent(
        before cutoff: Date,
        dryRun: Bool = false,
        reason: String = "manual-prune",
        includePinned: Bool = false
    ) throws -> ClipboardPruneResult {
        try pruneContent(
            dryRun: dryRun,
            reason: reason,
            exemptContentHashes: includePinned ? [] : pinnedContentHashes()
        ) { event in
            event.capturedAt < cutoff
        }
    }

    /// Keeps the newest `retainedItemLimit` UNPINNED events plus ALL pinned
    /// events — pinned items sit OUTSIDE the retention limit. Counting pins
    /// inside the limit would redact every new capture once pins reach the
    /// limit (silent capture breakage), so they never consume limit slots.
    @discardableResult
    public func pruneContent(
        keepingMostRecent retainedItemLimit: Int,
        dryRun: Bool = false,
        reason: String = "retention-limit",
        includePinned: Bool = false
    ) throws -> ClipboardPruneResult {
        guard retainedItemLimit >= 0 else {
            return ClipboardPruneResult(scannedEvents: 0, prunedEvents: 0, deletedBodyFiles: 0, changedFiles: 0, dryRun: dryRun)
        }
        let exemptContentHashes = includePinned ? Set<String>() : pinnedContentHashes()
        let retainedIDs = try mostRecentRetainedIDs(
            limit: retainedItemLimit,
            excludingContentHashes: exemptContentHashes
        )
        return try pruneContent(
            dryRun: dryRun,
            reason: reason,
            exemptContentHashes: exemptContentHashes
        ) { event in
            !retainedIDs.contains(event.id)
        }
    }

    private func pinnedContentHashes() -> Set<String> {
        ClipboardAnnotationsStore(archiveRoot: archiveRoot).pinnedContentHashes()
    }

    private func pruneContent(
        dryRun: Bool,
        reason: String,
        exemptContentHashes: Set<String>,
        shouldPrune: (StoredClipboardEvent) -> Bool
    ) throws -> ClipboardPruneResult {
        let reader = ClipboardArchiveReader(archiveRoot: archiveRoot)
        let suppression = try ClipboardSuppression(archiveRoot: archiveRoot).snapshot()
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]

        var scannedEvents = 0
        var prunedEvents = 0
        var deletedBodyFiles = 0
        var changedFiles = 0
        var exemptedPinnedEvents = 0
        var prunedIDs: [String] = []
        var prunedContentHashes = Set<String>()
        var survivingLiveContentHashes = Set<String>()

        for eventFile in try reader.eventFiles() {
            let originalLines = try String(contentsOf: eventFile)
                .split(separator: "\n", omittingEmptySubsequences: false)
                .map(String.init)
            var changed = false
            var rewrittenLines: [String] = []

            for line in originalLines {
                guard !line.isEmpty else {
                    continue
                }
                guard let data = line.data(using: .utf8),
                      var event = try? decoder.decode(StoredClipboardEvent.self, from: data) else {
                    rewrittenLines.append(line)
                    continue
                }

                scannedEvents += 1
                guard !suppression.isSuppressed(event) else {
                    rewrittenLines.append(line)
                    continue
                }
                if exemptContentHashes.contains(event.contentHash) {
                    if shouldPrune(event) {
                        exemptedPinnedEvents += 1
                    }
                    survivingLiveContentHashes.insert(event.contentHash)
                    rewrittenLines.append(line)
                    continue
                }
                guard shouldPrune(event) else {
                    survivingLiveContentHashes.insert(event.contentHash)
                    rewrittenLines.append(line)
                    continue
                }

                prunedEvents += 1
                prunedIDs.append(event.id)
                prunedContentHashes.insert(event.contentHash)
                if let rawContentPath = event.rawContentPath {
                    if let bodyURL = try? ClipboardArchivePath.containedURL(
                        relativePath: rawContentPath,
                        archiveRoot: archiveRoot
                    ) {
                        if FileManager.default.fileExists(atPath: bodyURL.path) {
                            deletedBodyFiles += 1
                            if !dryRun {
                                try FileManager.default.removeItem(at: bodyURL)
                            }
                        }
                    }
                }

                event.contentPreview = "[pruned]"
                event.contentInline = nil
                event.rawContentPath = nil
                event.privacyLabel = .doNotIndex
                event.allowedUse = [.doNotIndex]
                event.sensitivityFlags = Array(Set(event.sensitivityFlags + ["manually-pruned", reason])).sorted()

                if dryRun {
                    rewrittenLines.append(line)
                } else {
                    let redactedData = try encoder.encode(event)
                    guard let redactedLine = String(data: redactedData, encoding: .utf8) else {
                        throw ClipboardArchiveError.encodingFailed
                    }
                    rewrittenLines.append(redactedLine)
                    changed = true
                }
            }

            if changed {
                let payload = rewrittenLines.joined(separator: "\n") + "\n"
                let tempURL = eventFile.deletingLastPathComponent()
                    .appendingPathComponent(".\(eventFile.lastPathComponent).tmp-\(UUID().uuidString)")
                try payload.write(to: tempURL, atomically: true, encoding: .utf8)
                _ = try FileManager.default.replaceItemAt(eventFile, withItemAt: tempURL)
                try ClipboardPrivateFileSystem.secureFile(eventFile)
                changedFiles += 1
            }
        }

        if !dryRun {
            let ledger = ClipboardDeletionLedger(archiveRoot: archiveRoot)
            for id in prunedIDs {
                try ledger.recordDeletion(eventID: id, reason: reason)
            }
            _ = try ClipboardDerivedIndex(archiveRoot: archiveRoot, indexURL: indexURL).rebuild()
            sweepAnnotationReferences(
                prunedContentHashes: prunedContentHashes,
                survivingContentHashes: survivingLiveContentHashes
            )
        }

        return ClipboardPruneResult(
            scannedEvents: scannedEvents,
            prunedEvents: prunedEvents,
            deletedBodyFiles: deletedBodyFiles,
            changedFiles: changedFiles,
            dryRun: dryRun,
            exemptedPinnedEvents: exemptedPinnedEvents
        )
    }

    /// Annotation-reference sweep (contract 5): a content hash whose LAST
    /// live occurrence was just pruned loses its annotation record and
    /// collection memberships. Skipped on dry runs. Failures are swallowed —
    /// a newer-format (read-only) annotations file must not fail the prune,
    /// and a dangling reference is harmless because every consumer resolves
    /// annotations through live occurrences.
    private func sweepAnnotationReferences(
        prunedContentHashes: Set<String>,
        survivingContentHashes: Set<String>
    ) {
        let store = ClipboardAnnotationsStore(archiveRoot: archiveRoot)
        let document = store.document()
        for hash in prunedContentHashes.subtracting(survivingContentHashes).sorted() {
            let referenced = document.annotations[hash] != nil
                || document.collections.contains { $0.contentHashes.contains(hash) }
            guard referenced else {
                continue
            }
            try? store.removeContentReference(contentHash: hash)
        }
    }

    private func mostRecentRetainedIDs(
        limit: Int,
        excludingContentHashes exemptContentHashes: Set<String>
    ) throws -> Set<String> {
        guard limit > 0 else {
            return []
        }
        // Retained selection counts UNPINNED events only: exempt hashes are
        // protected by the exemption itself and must not consume limit slots.
        return Set(try liveEventReferences()
            .filter { !exemptContentHashes.contains($0.contentHash) }
            .sorted { $0.capturedAt > $1.capturedAt }
            .prefix(limit)
            .map(\.id))
    }

    // MARK: - Incremental retention enforcement

    /// One live (unsuppressed) event located during the enforcement scan.
    /// `contentHash` rides along from the single decode choke point so both
    /// prune paths can partition by pin state without a second scan.
    private struct LiveEventReference {
        var id: String
        var capturedAt: Date
        var fileURL: URL
        var contentHash: String
    }

    /// Scans every event file once and returns the live events with the
    /// index of the day file that holds each one.
    private func liveEventReferences() throws -> [LiveEventReference] {
        let reader = ClipboardArchiveReader(archiveRoot: archiveRoot)
        let suppression = try ClipboardSuppression(archiveRoot: archiveRoot).snapshot()
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        var live: [LiveEventReference] = []

        for eventFile in try reader.eventFiles() {
            let lines = try String(contentsOf: eventFile).split(separator: "\n", omittingEmptySubsequences: true)
            for line in lines {
                guard let data = String(line).data(using: .utf8),
                      let event = try? decoder.decode(StoredClipboardEvent.self, from: data),
                      !suppression.isSuppressed(event) else {
                    continue
                }
                live.append(LiveEventReference(
                    id: event.id,
                    capturedAt: event.capturedAt,
                    fileURL: eventFile,
                    contentHash: event.contentHash
                ))
            }
        }
        return live
    }

    /// Incremental retention enforcement (expansion contract 9).
    ///
    /// Unlike `pruneContent(keepingMostRecent:)` — which rewrites every day
    /// file and rebuilds the full search index — this:
    /// 1. returns immediately when the live-event count is at or under the
    ///    limit (no writes, no index work),
    /// 2. redacts only the overflow events, oldest first,
    /// 3. rewrites only the day files that actually contain overflow events,
    /// 4. issues per-event index deletes (batched in one sqlite call)
    ///    instead of a full index rebuild.
    ///
    /// Pin semantics (contract 5): pinned content sits OUTSIDE the retention
    /// limit — the guard, the overflow selection, and the limit itself apply
    /// to UNPINNED events only, and ALL pinned events are kept. Counting
    /// pins inside the limit would redact every new capture the moment pins
    /// reach the limit, silently breaking capture.
    @discardableResult
    public func enforceRetentionLimit(
        keepingMostRecent retainedItemLimit: Int,
        reason: String = "retention-limit"
    ) throws -> ClipboardRetentionEnforcementResult {
        guard retainedItemLimit >= 0 else {
            return ClipboardRetentionEnforcementResult(
                liveEvents: 0,
                prunedEvents: 0,
                deletedBodyFiles: 0,
                changedFiles: 0
            )
        }

        let live = try liveEventReferences()
        let pinnedHashes = pinnedContentHashes()
        let unpinnedLive = pinnedHashes.isEmpty
            ? live
            : live.filter { !pinnedHashes.contains($0.contentHash) }
        let exemptPinnedCount = live.count - unpinnedLive.count
        // Pinned-only over the limit is NOT overflow: zero writes.
        guard unpinnedLive.count > retainedItemLimit else {
            return ClipboardRetentionEnforcementResult(
                liveEvents: live.count,
                prunedEvents: 0,
                deletedBodyFiles: 0,
                changedFiles: 0,
                exemptPinnedEvents: exemptPinnedCount
            )
        }

        // Overflow = the oldest UNPINNED events beyond the limit.
        let overflow = unpinnedLive
            .sorted { $0.capturedAt < $1.capturedAt }
            .prefix(unpinnedLive.count - retainedItemLimit)
        var overflowIDsByFile: [URL: Set<String>] = [:]
        for reference in overflow {
            overflowIDsByFile[reference.fileURL, default: []].insert(reference.id)
        }
        let overflowIDs = overflow.map(\.id)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]

        var deletedBodyFiles = 0
        var changedFiles = 0

        // Fail-closed ordering: remove index rows BEFORE tombstoning the
        // archive lines. A crash after this point leaves events missing from
        // the index (benign, self-heals: they are still live and over-limit,
        // so the next enforcement pass re-selects them). The reverse order
        // could leave deleted content searchable in the index indefinitely,
        // because this incremental path never runs a full rebuild.
        _ = try ClipboardDerivedIndex(archiveRoot: archiveRoot, indexURL: indexURL)
            .delete(eventIDs: overflowIDs)

        for (eventFile, idsToPrune) in overflowIDsByFile.sorted(by: { $0.key.path < $1.key.path }) {
            let originalLines = try String(contentsOf: eventFile)
                .split(separator: "\n", omittingEmptySubsequences: true)
                .map(String.init)
            var changed = false
            var rewrittenLines: [String] = []

            for line in originalLines {
                guard let data = line.data(using: .utf8),
                      var event = try? decoder.decode(StoredClipboardEvent.self, from: data),
                      idsToPrune.contains(event.id) else {
                    rewrittenLines.append(line)
                    continue
                }

                if let rawContentPath = event.rawContentPath,
                   let bodyURL = try? ClipboardArchivePath.containedURL(
                       relativePath: rawContentPath,
                       archiveRoot: archiveRoot
                   ) {
                    if FileManager.default.fileExists(atPath: bodyURL.path) {
                        try FileManager.default.removeItem(at: bodyURL)
                        deletedBodyFiles += 1
                    }
                }

                event.contentPreview = "[pruned]"
                event.contentInline = nil
                event.rawContentPath = nil
                event.privacyLabel = .doNotIndex
                event.allowedUse = [.doNotIndex]
                event.sensitivityFlags = Array(Set(event.sensitivityFlags + ["manually-pruned", reason])).sorted()

                let redactedData = try encoder.encode(event)
                guard let redactedLine = String(data: redactedData, encoding: .utf8) else {
                    throw ClipboardArchiveError.encodingFailed
                }
                rewrittenLines.append(redactedLine)
                changed = true
            }

            if changed {
                let payload = rewrittenLines.joined(separator: "\n") + "\n"
                let tempURL = eventFile.deletingLastPathComponent()
                    .appendingPathComponent(".\(eventFile.lastPathComponent).tmp-\(UUID().uuidString)")
                try payload.write(to: tempURL, atomically: true, encoding: .utf8)
                _ = try FileManager.default.replaceItemAt(eventFile, withItemAt: tempURL)
                try ClipboardPrivateFileSystem.secureFile(eventFile)
                changedFiles += 1
            }
        }

        let ledger = ClipboardDeletionLedger(archiveRoot: archiveRoot)
        for id in overflowIDs {
            try ledger.recordDeletion(eventID: id, reason: reason)
        }

        let overflowIDSet = Set(overflowIDs)
        sweepAnnotationReferences(
            prunedContentHashes: Set(overflow.map(\.contentHash)),
            survivingContentHashes: Set(
                live.filter { !overflowIDSet.contains($0.id) }.map(\.contentHash)
            )
        )

        return ClipboardRetentionEnforcementResult(
            liveEvents: live.count,
            prunedEvents: overflowIDs.count,
            deletedBodyFiles: deletedBodyFiles,
            changedFiles: changedFiles,
            exemptPinnedEvents: exemptPinnedCount
        )
    }
}
