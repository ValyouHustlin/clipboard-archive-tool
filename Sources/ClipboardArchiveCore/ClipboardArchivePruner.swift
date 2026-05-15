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
        let deleted = try ClipboardDeletionLedger(archiveRoot: archiveRoot).deletedIDs()
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
                guard event.privacyLabel != .doNotIndex,
                      shouldPrune(event),
                      !deleted.contains(event.id) else {
                    rewrittenLines.append(line)
                    continue
                }

                prunedEvents += 1
                prunedIDs.append(event.id)
                if let rawContentPath = event.rawContentPath {
                    deletedBodyFiles += 1
                    if !dryRun {
                        let bodyURL = archiveRoot.appendingPathComponent(rawContentPath)
                        if FileManager.default.fileExists(atPath: bodyURL.path) {
                            try FileManager.default.removeItem(at: bodyURL)
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
        let reader = ClipboardArchiveReader(archiveRoot: archiveRoot)
        let deleted = try ClipboardDeletionLedger(archiveRoot: archiveRoot).deletedIDs()
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        var events: [StoredClipboardEvent] = []

        for eventFile in try reader.eventFiles() {
            let lines = try String(contentsOf: eventFile).split(separator: "\n", omittingEmptySubsequences: true)
            for line in lines {
                guard let data = String(line).data(using: .utf8),
                      let event = try? decoder.decode(StoredClipboardEvent.self, from: data),
                      event.privacyLabel != .doNotIndex,
                      !deleted.contains(event.id) else {
                    continue
                }
                events.append(event)
            }
        }

        return Set(events
            .sorted { $0.capturedAt > $1.capturedAt }
            .prefix(limit)
            .map(\.id))
    }
}
