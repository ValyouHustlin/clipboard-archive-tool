import Foundation

public struct ClipboardPruneResult: Codable, Equatable, Sendable {
    public var scannedEvents: Int
    public var prunedEvents: Int
    public var deletedBodyFiles: Int
    public var changedFiles: Int
    public var dryRun: Bool

    public init(
        scannedEvents: Int,
        prunedEvents: Int,
        deletedBodyFiles: Int,
        changedFiles: Int,
        dryRun: Bool
    ) {
        self.scannedEvents = scannedEvents
        self.prunedEvents = prunedEvents
        self.deletedBodyFiles = deletedBodyFiles
        self.changedFiles = changedFiles
        self.dryRun = dryRun
    }
}

public struct ClipboardRetentionEnforcementResult: Codable, Equatable, Sendable {
    /// Live (unsuppressed) events found by the enforcement scan, counted
    /// before any pruning done by this call.
    public var liveEvents: Int
    public var prunedEvents: Int
    public var deletedBodyFiles: Int
    public var changedFiles: Int

    /// Live events remaining after this call.
    public var keptEvents: Int {
        liveEvents - prunedEvents
    }

    public init(
        liveEvents: Int,
        prunedEvents: Int,
        deletedBodyFiles: Int,
        changedFiles: Int
    ) {
        self.liveEvents = liveEvents
        self.prunedEvents = prunedEvents
        self.deletedBodyFiles = deletedBodyFiles
        self.changedFiles = changedFiles
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

    @discardableResult
    public func pruneContent(before cutoff: Date, dryRun: Bool = false, reason: String = "manual-prune") throws -> ClipboardPruneResult {
        try pruneContent(dryRun: dryRun, reason: reason) { event in
            event.capturedAt < cutoff
        }
    }

    @discardableResult
    public func pruneContent(keepingMostRecent retainedItemLimit: Int, dryRun: Bool = false, reason: String = "retention-limit") throws -> ClipboardPruneResult {
        guard retainedItemLimit >= 0 else {
            return ClipboardPruneResult(scannedEvents: 0, prunedEvents: 0, deletedBodyFiles: 0, changedFiles: 0, dryRun: dryRun)
        }
        let retainedIDs = try mostRecentRetainedIDs(limit: retainedItemLimit)
        return try pruneContent(dryRun: dryRun, reason: reason) { event in
            !retainedIDs.contains(event.id)
        }
    }

    private func pruneContent(
        dryRun: Bool,
        reason: String,
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
        var prunedIDs: [String] = []

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
                guard !suppression.isSuppressed(event),
                      shouldPrune(event) else {
                    rewrittenLines.append(line)
                    continue
                }

                prunedEvents += 1
                prunedIDs.append(event.id)
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
        }

        return ClipboardPruneResult(
            scannedEvents: scannedEvents,
            prunedEvents: prunedEvents,
            deletedBodyFiles: deletedBodyFiles,
            changedFiles: changedFiles,
            dryRun: dryRun
        )
    }

    private func mostRecentRetainedIDs(limit: Int) throws -> Set<String> {
        guard limit > 0 else {
            return []
        }
        return Set(try liveEventReferences()
            .sorted { $0.capturedAt > $1.capturedAt }
            .prefix(limit)
            .map(\.id))
    }

    // MARK: - Incremental retention enforcement

    /// One live (unsuppressed) event located during the enforcement scan.
    private struct LiveEventReference {
        var id: String
        var capturedAt: Date
        var fileURL: URL
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
                    fileURL: eventFile
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
        guard live.count > retainedItemLimit else {
            return ClipboardRetentionEnforcementResult(
                liveEvents: live.count,
                prunedEvents: 0,
                deletedBodyFiles: 0,
                changedFiles: 0
            )
        }

        // Overflow = the oldest events beyond the limit.
        let overflow = live
            .sorted { $0.capturedAt < $1.capturedAt }
            .prefix(live.count - retainedItemLimit)
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

        return ClipboardRetentionEnforcementResult(
            liveEvents: live.count,
            prunedEvents: overflowIDs.count,
            deletedBodyFiles: deletedBodyFiles,
            changedFiles: changedFiles
        )
    }
}
