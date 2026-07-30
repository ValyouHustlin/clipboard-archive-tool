import Foundation

public enum ClipboardIndexUpdateStatus: Equatable, Sendable {
    case notConfigured
    case updated
    case failed
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
            var event = try archiveWriter.archiveAllowedCapture(capture)
            event.sensitivityFlags = flags
            let indexUpdate: ClipboardIndexUpdateStatus
            if let derivedIndex {
                do {
                    try derivedIndex.upsert(event: event, body: capture.content)
                    indexUpdate = .updated
                } catch {
                    indexUpdate = .failed
                }
            } else {
                indexUpdate = .notConfigured
            }
            return .stored(event, indexUpdate: indexUpdate)

        case let .block(reason):
            try archiveWriter.archiveBlockedCapture(capture, reason: reason)
            return .blocked(reason: reason)
        }
    }
}
