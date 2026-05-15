import Foundation

public enum ClipboardIngestResult: Equatable, Sendable {
    case stored(StoredClipboardEvent)
    case blocked(reason: String)
}

public struct ClipboardIngestor: Sendable {
    public var filter: ClipboardPrivacyFilter
    public var archiveWriter: ClipboardArchiveWriter

    public init(
        filter: ClipboardPrivacyFilter = ClipboardPrivacyFilter(),
        archiveWriter: ClipboardArchiveWriter
    ) {
        self.filter = filter
        self.archiveWriter = archiveWriter
    }

    @discardableResult
    public func ingest(_ capture: ClipboardCapture) throws -> ClipboardIngestResult {
        switch filter.evaluate(capture) {
        case let .allow(flags):
            var event = try archiveWriter.archiveAllowedCapture(capture)
            event.sensitivityFlags = flags
            return .stored(event)

        case let .block(reason):
            try archiveWriter.archiveBlockedCapture(capture, reason: reason)
            return .blocked(reason: reason)
        }
    }
}

