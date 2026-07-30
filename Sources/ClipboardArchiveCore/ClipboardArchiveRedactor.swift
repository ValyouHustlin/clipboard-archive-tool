import Foundation

public struct ClipboardRedactionResult: Equatable, Sendable {
    public var eventID: String
    public var redactedEventFile: String
    public var deletedBodyFile: String?
    public var deletedFromIndex: Bool
    public var skippedUnsafeBodyPath: Bool
    /// Non-nil when this redaction removed the LAST live occurrence of an
    /// annotated content hash, so its annotation record and collection
    /// memberships were dropped too (contract 5).
    public var removedAnnotationContentHash: String?

    public init(
        eventID: String,
        redactedEventFile: String,
        deletedBodyFile: String?,
        deletedFromIndex: Bool,
        skippedUnsafeBodyPath: Bool = false,
        removedAnnotationContentHash: String? = nil
    ) {
        self.eventID = eventID
        self.redactedEventFile = redactedEventFile
        self.deletedBodyFile = deletedBodyFile
        self.deletedFromIndex = deletedFromIndex
        self.skippedUnsafeBodyPath = skippedUnsafeBodyPath
        self.removedAnnotationContentHash = removedAnnotationContentHash
    }
}

public struct ClipboardArchiveRedactor: Sendable {
    public var archiveRoot: URL
    public var indexURL: URL

    public init(archiveRoot: URL, indexURL: URL = ClipboardDefaults.indexURL()) {
        self.archiveRoot = archiveRoot
        self.indexURL = indexURL
    }

    @discardableResult
    public func redact(eventID: String, reason: String = "manual-delete") throws -> ClipboardRedactionResult {
        let reader = ClipboardArchiveReader(archiveRoot: archiveRoot)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]

        for eventFile in try reader.eventFiles() {
            let originalLines = try String(contentsOf: eventFile)
                .split(separator: "\n", omittingEmptySubsequences: false)
                .map(String.init)
            var changed = false
            var deletedBodyFile: String?
            var skippedUnsafeBodyPath = false
            var redactedContentHash: String?
            var rewrittenLines: [String] = []

            for line in originalLines {
                guard !line.isEmpty,
                      let data = line.data(using: .utf8),
                      var event = try? decoder.decode(StoredClipboardEvent.self, from: data),
                      event.id == eventID else {
                    if !line.isEmpty {
                        rewrittenLines.append(line)
                    }
                    continue
                }

                // Content identity, captured pre-tombstone, for the
                // last-occurrence annotation cleanup below.
                redactedContentHash = event.contentHash

                if let rawContentPath = event.rawContentPath {
                    if let bodyURL = try? ClipboardArchivePath.containedURL(
                        relativePath: rawContentPath,
                        archiveRoot: archiveRoot
                    ) {
                        if FileManager.default.fileExists(atPath: bodyURL.path) {
                            try FileManager.default.removeItem(at: bodyURL)
                        }
                        deletedBodyFile = rawContentPath
                    } else {
                        skippedUnsafeBodyPath = true
                    }
                }

                // Rich body deletion (Slice 6): the image/RTF/file-list
                // body is content too — same containment rules, same
                // unsafe-path reporting as the plain body above.
                if let richBodyPath = event.richContent?.bodyPath {
                    if let bodyURL = try? ClipboardArchivePath.containedURL(
                        relativePath: richBodyPath,
                        archiveRoot: archiveRoot
                    ) {
                        if FileManager.default.fileExists(atPath: bodyURL.path) {
                            try FileManager.default.removeItem(at: bodyURL)
                        }
                        if deletedBodyFile == nil {
                            deletedBodyFile = richBodyPath
                        }
                    } else {
                        skippedUnsafeBodyPath = true
                    }
                }

                event.contentPreview = "[deleted]"
                event.contentInline = nil
                event.rawContentPath = nil
                event.richContent = nil
                event.privacyLabel = .doNotIndex
                event.allowedUse = [.doNotIndex]
                event.sensitivityFlags = Array(Set(event.sensitivityFlags + ["manually-deleted", reason])).sorted()

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
                try ClipboardDeletionLedger(archiveRoot: archiveRoot).recordDeletion(eventID: eventID, reason: reason)
                let deletedFromIndex = try ClipboardDerivedIndex(archiveRoot: archiveRoot, indexURL: indexURL)
                    .delete(eventID: eventID)
                var removedAnnotationContentHash: String?
                if let redactedContentHash {
                    removedAnnotationContentHash = cleanUpAnnotationIfLastOccurrence(
                        contentHash: redactedContentHash
                    )
                }
                return ClipboardRedactionResult(
                    eventID: eventID,
                    redactedEventFile: eventFile.path,
                    deletedBodyFile: deletedBodyFile,
                    deletedFromIndex: deletedFromIndex,
                    skippedUnsafeBodyPath: skippedUnsafeBodyPath,
                    removedAnnotationContentHash: removedAnnotationContentHash
                )
            }
        }

        throw ClipboardArchiveError.eventNotFound(eventID)
    }

    /// Contract 5 cleanup: when the event just redacted was the LAST live
    /// occurrence of an annotated content hash, drop the annotation record
    /// and its collection memberships.
    ///
    /// The live-occurrence count comes from `ClipboardOccurrenceResolver`
    /// (content_hash index query post-filtered through the deletion ledger —
    /// a stale index must not keep an annotation alive; a missing index
    /// falls back to one reader scan). A resolver failure keeps the
    /// annotation (conservative). Removal in read-only newer-format mode is
    /// silently skipped: the dangling reference is harmless because all
    /// consumers resolve annotations through live occurrences.
    private func cleanUpAnnotationIfLastOccurrence(contentHash: String) -> String? {
        let store = ClipboardAnnotationsStore(archiveRoot: archiveRoot)
        let document = store.document()
        let referenced = document.annotations[contentHash] != nil
            || document.collections.contains { $0.contentHashes.contains(contentHash) }
        guard referenced else {
            return nil
        }
        guard let remaining = try? ClipboardOccurrenceResolver(
            archiveRoot: archiveRoot,
            indexURL: indexURL
        ).liveOccurrenceIDs(contentHash: contentHash), remaining.isEmpty else {
            return nil
        }
        guard (try? store.removeContentReference(contentHash: contentHash)) != nil else {
            return nil
        }
        return contentHash
    }
}

public enum ClipboardArchiveError: Error, Equatable, CustomStringConvertible, Sendable {
    case eventNotFound(String)
    case encodingFailed

    public var description: String {
        switch self {
        case let .eventNotFound(id):
            return "clipboard event not found: \(id)"
        case .encodingFailed:
            return "failed to encode clipboard archive event"
        }
    }
}
