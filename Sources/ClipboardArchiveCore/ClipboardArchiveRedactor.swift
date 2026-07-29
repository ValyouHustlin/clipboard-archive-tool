import Foundation

public struct ClipboardRedactionResult: Equatable, Sendable {
    public var eventID: String
    public var redactedEventFile: String
    public var deletedBodyFile: String?
    public var deletedFromIndex: Bool
    public var skippedUnsafeBodyPath: Bool

    public init(
        eventID: String,
        redactedEventFile: String,
        deletedBodyFile: String?,
        deletedFromIndex: Bool,
        skippedUnsafeBodyPath: Bool = false
    ) {
        self.eventID = eventID
        self.redactedEventFile = redactedEventFile
        self.deletedBodyFile = deletedBodyFile
        self.deletedFromIndex = deletedFromIndex
        self.skippedUnsafeBodyPath = skippedUnsafeBodyPath
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

                event.contentPreview = "[deleted]"
                event.contentInline = nil
                event.rawContentPath = nil
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
                return ClipboardRedactionResult(
                    eventID: eventID,
                    redactedEventFile: eventFile.path,
                    deletedBodyFile: deletedBodyFile,
                    deletedFromIndex: deletedFromIndex,
                    skippedUnsafeBodyPath: skippedUnsafeBodyPath
                )
            }
        }

        throw ClipboardArchiveError.eventNotFound(eventID)
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
