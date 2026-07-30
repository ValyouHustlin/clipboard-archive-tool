import Foundation

public struct ClipboardDeletionEvent: Codable, Equatable, Sendable {
    public var eventType: String
    public var clipboardEventID: String
    public var deletedAt: Date
    public var reason: String

    public init(clipboardEventID: String, deletedAt: Date = Date(), reason: String) {
        self.eventType = "clipboard_event_deleted"
        self.clipboardEventID = clipboardEventID
        self.deletedAt = deletedAt
        self.reason = reason
    }
}

/// One cheap stat record per ledger file. The full signature (file set +
/// per-file size and modification time) changes whenever any process — this
/// one or another — creates, appends to, or removes a ledger file, so a
/// signature match proves the cached id set is still current.
private struct LedgerFileSignature: Equatable {
    var path: String
    var byteCount: Int
    var modifiedAt: Date
}

/// In-process cache of parsed deletion-ledger ids, keyed by ledger directory
/// path so every `ClipboardDeletionLedger` value sharing an archive root also
/// shares the cache. Validated on every read with a directory listing plus a
/// per-file size/mtime stat instead of a full re-read; appends through this
/// process invalidate the entry directly.
private final class ClipboardDeletionLedgerCache: @unchecked Sendable {
    static let shared = ClipboardDeletionLedgerCache()

    private let lock = NSLock()
    private var entries: [String: (signature: [LedgerFileSignature], ids: Set<String>)] = [:]

    func cachedIDs(ledgerRoot: String, signature: [LedgerFileSignature]) -> Set<String>? {
        lock.lock()
        defer { lock.unlock() }
        guard let entry = entries[ledgerRoot], entry.signature == signature else {
            return nil
        }
        return entry.ids
    }

    func store(ledgerRoot: String, signature: [LedgerFileSignature], ids: Set<String>) {
        lock.lock()
        defer { lock.unlock() }
        entries[ledgerRoot] = (signature, ids)
    }

    func invalidate(ledgerRoot: String) {
        lock.lock()
        defer { lock.unlock() }
        entries[ledgerRoot] = nil
    }
}

public struct ClipboardDeletionLedger: Sendable {
    public var archiveRoot: URL

    public init(archiveRoot: URL) {
        self.archiveRoot = archiveRoot
    }

    public func recordDeletion(eventID: String, reason: String = "manual-delete") throws {
        let event = ClipboardDeletionEvent(clipboardEventID: eventID, reason: reason)
        let url = ledgerURL(for: event.deletedAt)
        try ClipboardPrivateFileSystem.createDirectory(
            url.deletingLastPathComponent(),
            archiveRoot: archiveRoot
        )

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        var data = try encoder.encode(event)
        data.append(0x0A)

        if FileManager.default.fileExists(atPath: url.path) {
            let handle = try FileHandle(forWritingTo: url)
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
            try handle.close()
        } else {
            try data.write(to: url, options: [.atomic])
        }
        try ClipboardPrivateFileSystem.secureFile(url)
        ClipboardDeletionLedgerCache.shared.invalidate(ledgerRoot: ledgerRootKey())
    }

    public func deletedIDs() throws -> Set<String> {
        let root = archiveRoot.appendingPathComponent("deletion-ledger")
        guard FileManager.default.fileExists(atPath: root.path) else {
            return []
        }

        // Cheap freshness check: one directory listing plus one stat per
        // ledger file. Any append (including one made by another process)
        // changes a file's size, so a matching signature means the cached
        // parse is still valid and the full re-read can be skipped.
        let ledgerFiles = try ledgerFileURLs(root: root)
        var signature: [LedgerFileSignature] = []
        signature.reserveCapacity(ledgerFiles.count)
        for url in ledgerFiles {
            let values = try url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
            signature.append(LedgerFileSignature(
                path: url.path,
                byteCount: values.fileSize ?? 0,
                modifiedAt: values.contentModificationDate ?? Date.distantPast
            ))
        }

        let cacheKey = ledgerRootKey()
        if let cached = ClipboardDeletionLedgerCache.shared.cachedIDs(ledgerRoot: cacheKey, signature: signature) {
            return cached
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        var ids = Set<String>()

        for url in ledgerFiles {
            let lines = try String(contentsOf: url).split(separator: "\n", omittingEmptySubsequences: true)
            for line in lines {
                guard let data = String(line).data(using: .utf8),
                      let event = try? decoder.decode(ClipboardDeletionEvent.self, from: data) else {
                    continue
                }
                ids.insert(event.clipboardEventID)
            }
        }

        ClipboardDeletionLedgerCache.shared.store(ledgerRoot: cacheKey, signature: signature, ids: ids)
        return ids
    }

    private func ledgerFileURLs(root: URL) throws -> [URL] {
        let urls = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles]
        )?.compactMap { $0 as? URL } ?? []

        return try urls
            .filter { url in
                guard url.pathExtension == "ndjson" else {
                    return false
                }
                let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
                return values.isRegularFile == true && values.isSymbolicLink != true
            }
            .sorted { $0.path < $1.path }
    }

    private func ledgerRootKey() -> String {
        archiveRoot.standardizedFileURL
            .appendingPathComponent("deletion-ledger")
            .path
    }

    private func ledgerURL(for date: Date) -> URL {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        let day = formatter.string(from: date)
        return archiveRoot
            .appendingPathComponent("deletion-ledger")
            .appendingPathComponent("\(day)_deletions.ndjson")
    }
}
