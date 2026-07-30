import Foundation

/// One user annotation keyed by content hash (expansion contract 5).
/// Content identity — `sha256:<hex>` — survives re-copies of the same text,
/// so pins/tags/snippets follow the content, not one occurrence.
///
/// `sensitivityOverride` and `expiresAt` are Slice 5 placeholders: they are
/// round-tripped losslessly but never acted on in Slice 4.
public struct ClipboardAnnotationRecord: Codable, Equatable, Sendable {
    public var pinned: Bool
    public var pinnedAt: Date?
    public var tags: [String]
    public var snippet: Bool
    public var snippetTitle: String?
    public var sensitivityOverride: String?
    public var expiresAt: Date?

    public init(
        pinned: Bool = false,
        pinnedAt: Date? = nil,
        tags: [String] = [],
        snippet: Bool = false,
        snippetTitle: String? = nil,
        sensitivityOverride: String? = nil,
        expiresAt: Date? = nil
    ) {
        self.pinned = pinned
        self.pinnedAt = pinnedAt
        self.tags = tags
        self.snippet = snippet
        self.snippetTitle = snippetTitle
        self.sensitivityOverride = sensitivityOverride
        self.expiresAt = expiresAt
    }

    /// A record equal to the default carries no information; such records
    /// are garbage-collected on save so the file never accretes noise.
    public var isDefault: Bool {
        self == ClipboardAnnotationRecord()
    }

    private enum CodingKeys: String, CodingKey {
        case pinned
        case pinnedAt
        case tags
        case snippet
        case snippetTitle
        case sensitivityOverride
        case expiresAt
    }

    /// Tolerant decode: every field is optional with a safe default so a
    /// record written by a newer build (extra fields, missing fields) still
    /// loads its known fields.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        pinned = try container.decodeIfPresent(Bool.self, forKey: .pinned) ?? false
        pinnedAt = try container.decodeIfPresent(Date.self, forKey: .pinnedAt)
        tags = try container.decodeIfPresent([String].self, forKey: .tags) ?? []
        snippet = try container.decodeIfPresent(Bool.self, forKey: .snippet) ?? false
        snippetTitle = try container.decodeIfPresent(String.self, forKey: .snippetTitle)
        sensitivityOverride = try container.decodeIfPresent(String.self, forKey: .sensitivityOverride)
        expiresAt = try container.decodeIfPresent(Date.self, forKey: .expiresAt)
    }
}

/// A named, ordered list of content hashes (expansion contract 5).
public struct ClipboardAnnotationCollection: Codable, Equatable, Sendable {
    public var id: String
    public var name: String
    public var createdAt: Date
    public var contentHashes: [String]

    public init(
        id: String = "col_\(UUID().uuidString)",
        name: String,
        createdAt: Date = Date(),
        contentHashes: [String] = []
    ) {
        self.id = id
        self.name = name
        self.createdAt = createdAt
        self.contentHashes = contentHashes
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case name
        case createdAt
        case contentHashes
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(String.self, forKey: .id) ?? "col_\(UUID().uuidString)"
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? "Untitled"
        createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt) ?? .distantPast
        contentHashes = try container.decodeIfPresent([String].self, forKey: .contentHashes) ?? []
    }
}

/// The whole sidecar document. Version missing decodes as 1; a version
/// greater than `currentVersion` puts the store into read-only mode.
public struct ClipboardAnnotationsDocument: Codable, Equatable, Sendable {
    public static let currentVersion = 1

    public var annotationsVersion: Int
    public var updatedAt: Date
    public var annotations: [String: ClipboardAnnotationRecord]
    public var collections: [ClipboardAnnotationCollection]

    public init(
        annotationsVersion: Int = ClipboardAnnotationsDocument.currentVersion,
        updatedAt: Date = Date(),
        annotations: [String: ClipboardAnnotationRecord] = [:],
        collections: [ClipboardAnnotationCollection] = []
    ) {
        self.annotationsVersion = annotationsVersion
        self.updatedAt = updatedAt
        self.annotations = annotations
        self.collections = collections
    }

    private enum CodingKeys: String, CodingKey {
        case annotationsVersion
        case updatedAt
        case annotations
        case collections
    }

    /// Tolerant decode following the settings-store pattern: one malformed
    /// annotation or collection entry drops only that entry, never the whole
    /// document (which would silently lose every pin).
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        annotationsVersion = try container.decodeIfPresent(Int.self, forKey: .annotationsVersion) ?? 1
        updatedAt = try container.decodeIfPresent(Date.self, forKey: .updatedAt) ?? .distantPast
        let tolerantAnnotations = try container.decodeIfPresent(
            [String: FailableDecodable<ClipboardAnnotationRecord>].self,
            forKey: .annotations
        ) ?? [:]
        annotations = tolerantAnnotations.compactMapValues(\.value)
        let tolerantCollections = try container.decodeIfPresent(
            [FailableDecodable<ClipboardAnnotationCollection>].self,
            forKey: .collections
        ) ?? []
        collections = tolerantCollections.compactMap(\.value)
    }
}

public enum ClipboardAnnotationsError: Error, Equatable, CustomStringConvertible, Sendable {
    /// The file on disk was saved by a newer build. Reads still work for
    /// known fields (pins keep protecting); every mutation is refused so the
    /// newer build's data is never clobbered. The file stays byte-identical.
    case newerFormat(Int)
    case collectionNotFound(String)
    case invalidCollectionMove

    public var description: String {
        switch self {
        case let .newerFormat(version):
            return "annotations file was saved by a newer version of Clipboard Archive (format \(version))"
        case let .collectionNotFound(id):
            return "collection not found: \(id)"
        case .invalidCollectionMove:
            return "collection move indexes out of range"
        }
    }
}

/// One cheap stat signature per annotations file (ledger-cache pattern):
/// any write — by this process or another — changes size or mtime, so a
/// matching signature proves the cached parse is current.
private struct AnnotationsFileSignature: Equatable {
    var byteCount: Int
    var modifiedAt: Date
}

private enum AnnotationsLoadState {
    case absent
    case ok(ClipboardAnnotationsDocument)
    case corrupt
    case newerFormat(ClipboardAnnotationsDocument)
}

private final class ClipboardAnnotationsCache: @unchecked Sendable {
    static let shared = ClipboardAnnotationsCache()

    private let lock = NSLock()
    private var entries: [String: (signature: AnnotationsFileSignature, state: AnnotationsLoadState)] = [:]

    func cachedState(path: String, signature: AnnotationsFileSignature) -> AnnotationsLoadState? {
        lock.lock()
        defer { lock.unlock() }
        guard let entry = entries[path], entry.signature == signature else {
            return nil
        }
        return entry.state
    }

    func store(path: String, signature: AnnotationsFileSignature, state: AnnotationsLoadState) {
        lock.lock()
        defer { lock.unlock() }
        entries[path] = (signature, state)
    }

    func invalidate(path: String) {
        lock.lock()
        defer { lock.unlock() }
        entries[path] = nil
    }
}

/// Sidecar store for pins, tags, collections, and snippets (expansion
/// contract 5). The archive stays append-oriented: annotation toggles never
/// rewrite day files.
///
/// Durability rules:
/// - `<archiveRoot>/annotations/annotations.json`, 0700 directory / 0600
///   file, atomic temp + `replaceItemAt` writes, symlink-rejecting load.
/// - No file is created until the first mutation.
/// - A corrupt file reads as an empty document; the FIRST mutation renames
///   it aside to `annotations.json.corrupt-<ISO8601>` before writing fresh.
///   Reads never mutate anything.
/// - `annotationsVersion` above `currentVersion` means READ-ONLY: known
///   fields still load (pins still protect retention), every mutation throws
///   `.newerFormat`, and the file stays byte-identical.
/// - Single writer: the GUI app is the only mutator; the CLI reads only.
public struct ClipboardAnnotationsStore: Sendable {
    public var archiveRoot: URL

    public init(archiveRoot: URL) {
        self.archiveRoot = archiveRoot
    }

    public var annotationsDirectoryURL: URL {
        archiveRoot.appendingPathComponent("annotations", isDirectory: true)
    }

    public var annotationsFileURL: URL {
        annotationsDirectoryURL.appendingPathComponent("annotations.json")
    }

    // MARK: - Reads

    /// The current document; empty for absent or corrupt files. Reads are
    /// side-effect free.
    public func document() -> ClipboardAnnotationsDocument {
        switch loadState() {
        case .absent, .corrupt:
            return ClipboardAnnotationsDocument(updatedAt: .distantPast)
        case let .ok(document), let .newerFormat(document):
            return document
        }
    }

    /// True when the on-disk file was written by a newer build and every
    /// mutation will throw `.newerFormat`.
    public func isReadOnly() -> Bool {
        if case .newerFormat = loadState() {
            return true
        }
        return false
    }

    public func annotation(for contentHash: String) -> ClipboardAnnotationRecord? {
        document().annotations[contentHash]
    }

    public func pinnedContentHashes() -> Set<String> {
        Set(document().annotations.filter { $0.value.pinned }.keys)
    }

    /// Snippet records (pinned annotations flagged `snippet: true`), sorted
    /// by title then hash for a stable UI order.
    public func snippets() -> [(contentHash: String, record: ClipboardAnnotationRecord)] {
        document().annotations
            .filter { $0.value.snippet }
            .map { (contentHash: $0.key, record: $0.value) }
            .sorted {
                let left = $0.record.snippetTitle ?? ""
                let right = $1.record.snippetTitle ?? ""
                if left.localizedCaseInsensitiveCompare(right) == .orderedSame {
                    return $0.contentHash < $1.contentHash
                }
                return left.localizedCaseInsensitiveCompare(right) == .orderedAscending
            }
    }

    /// Every distinct tag across all records (case-insensitive dedupe,
    /// first-seen casing preserved), sorted case-insensitively.
    public func allTags() -> [String] {
        var seen = Set<String>()
        var tags: [String] = []
        for record in document().annotations.values.sorted(by: { $0.tags.joined() < $1.tags.joined() }) {
            for tag in record.tags where seen.insert(tag.lowercased()).inserted {
                tags.append(tag)
            }
        }
        return tags.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    public func collections() -> [ClipboardAnnotationCollection] {
        document().collections
    }

    /// Content hashes carrying the manual `"restricted"` sensitivity
    /// override (Slice 5). Index writers exclude these; readers never do.
    public func restrictedContentHashes() -> Set<String> {
        Set(document().annotations.filter { $0.value.sensitivityOverride == "restricted" }.keys)
    }

    /// Every record with an expiry, sorted soonest first.
    public func entriesWithExpiry() -> [(contentHash: String, expiresAt: Date)] {
        document().annotations
            .compactMap { key, record in
                record.expiresAt.map { (contentHash: key, expiresAt: $0) }
            }
            .sorted {
                if $0.expiresAt == $1.expiresAt {
                    return $0.contentHash < $1.contentHash
                }
                return $0.expiresAt < $1.expiresAt
            }
    }

    /// The soonest pending expiry, or nil when nothing expires. This is the
    /// sweeper's `nextDue` source: ONE stat-validated cache read, zero
    /// archive IO.
    public func earliestExpiry() -> Date? {
        document().annotations.values.compactMap(\.expiresAt).min()
    }

    /// Trim whitespace, drop empties, case-insensitive dedupe keeping the
    /// first-seen casing and order.
    public static func normalizedTags(_ tags: [String]) -> [String] {
        var seen = Set<String>()
        var normalized: [String] = []
        for tag in tags {
            let trimmed = tag.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, seen.insert(trimmed.lowercased()).inserted else {
                continue
            }
            normalized.append(trimmed)
        }
        return normalized
    }

    // MARK: - Mutations (GUI single-writer only)

    public func setPinned(_ pinned: Bool, forContentHash contentHash: String) throws {
        try mutate { document in
            var record = document.annotations[contentHash] ?? ClipboardAnnotationRecord()
            if pinned {
                record.pinned = true
                if record.pinnedAt == nil {
                    record.pinnedAt = Date()
                }
            } else {
                // Invariant: snippet ⇒ pinned, so unpinning clears the
                // snippet flag too (the UI warns before doing this).
                record.pinned = false
                record.pinnedAt = nil
                record.snippet = false
                record.snippetTitle = nil
            }
            document.annotations[contentHash] = record
        }
    }

    public func setTags(_ tags: [String], forContentHash contentHash: String) throws {
        try mutate { document in
            var record = document.annotations[contentHash] ?? ClipboardAnnotationRecord()
            record.tags = Self.normalizedTags(tags)
            document.annotations[contentHash] = record
        }
    }

    /// Invariant: snippet ⇒ pinned. Marking a snippet pins the content;
    /// clearing the snippet flag leaves the pin in place.
    public func setSnippet(
        _ isSnippet: Bool,
        title: String?,
        forContentHash contentHash: String
    ) throws {
        try mutate { document in
            var record = document.annotations[contentHash] ?? ClipboardAnnotationRecord()
            if isSnippet {
                record.snippet = true
                let trimmed = title?.trimmingCharacters(in: .whitespacesAndNewlines)
                record.snippetTitle = (trimmed?.isEmpty ?? true) ? nil : trimmed
                record.pinned = true
                if record.pinnedAt == nil {
                    record.pinnedAt = Date()
                }
            } else {
                record.snippet = false
                record.snippetTitle = nil
            }
            document.annotations[contentHash] = record
        }
    }

    /// Manual sensitivity override (Slice 5). `"restricted"` keeps the
    /// content stored and visible but out of the search index; nil clears.
    /// Event lines are never rewritten — the override survives re-copies via
    /// content hash. Also updates the tolerant placeholder round-trip shape.
    public func setSensitivityOverride(
        _ sensitivityOverride: String?,
        forContentHash contentHash: String
    ) throws {
        try mutate { document in
            var record = document.annotations[contentHash] ?? ClipboardAnnotationRecord()
            record.sensitivityOverride = sensitivityOverride
            document.annotations[contentHash] = record
        }
    }

    /// Expiring sensitive clip (Slice 5): at `expiresAt` the sweeper deletes
    /// EVERY live occurrence of the content — including pinned ones (expiry
    /// is the user's explicit instruction; the UI states this when setting
    /// expiry on a pinned clip). nil clears the expiry.
    public func setExpiry(_ expiresAt: Date?, forContentHash contentHash: String) throws {
        try mutate { document in
            var record = document.annotations[contentHash] ?? ClipboardAnnotationRecord()
            record.expiresAt = expiresAt
            document.annotations[contentHash] = record
        }
    }

    @discardableResult
    public func createCollection(named name: String) throws -> ClipboardAnnotationCollection {
        let collection = ClipboardAnnotationCollection(name: name)
        try mutate { document in
            document.collections.append(collection)
        }
        return collection
    }

    public func renameCollection(id: String, to name: String) throws {
        try mutate { document in
            guard let index = document.collections.firstIndex(where: { $0.id == id }) else {
                return
            }
            document.collections[index].name = name
        }
    }

    public func deleteCollection(id: String) throws {
        try mutate { document in
            document.collections.removeAll { $0.id == id }
        }
    }

    public func setMembership(
        contentHash: String,
        inCollection id: String,
        isMember: Bool
    ) throws {
        try mutate { document in
            guard let index = document.collections.firstIndex(where: { $0.id == id }) else {
                return
            }
            var hashes = document.collections[index].contentHashes
            if isMember {
                if !hashes.contains(contentHash) {
                    hashes.append(contentHash)
                }
            } else {
                hashes.removeAll { $0 == contentHash }
            }
            document.collections[index].contentHashes = hashes
        }
    }

    /// Reorders one item inside a collection (`contentHashes` order is the
    /// collection's display order).
    public func moveItem(inCollection id: String, fromIndex: Int, toIndex: Int) throws {
        try mutate { document in
            guard let index = document.collections.firstIndex(where: { $0.id == id }) else {
                return
            }
            var hashes = document.collections[index].contentHashes
            guard fromIndex >= 0, fromIndex < hashes.count,
                  toIndex >= 0, toIndex < hashes.count else {
                return
            }
            let moved = hashes.remove(at: fromIndex)
            hashes.insert(moved, at: toIndex)
            document.collections[index].contentHashes = hashes
        }
    }

    /// Drops the record for a content hash and strips it from every
    /// collection. Called only when the LAST live occurrence of that content
    /// is gone (redaction or pruning), never on ordinary deletes of one copy.
    public func removeContentReference(contentHash: String) throws {
        try mutate { document in
            document.annotations[contentHash] = nil
            for index in document.collections.indices {
                document.collections[index].contentHashes.removeAll { $0 == contentHash }
            }
        }
    }

    // MARK: - Load / save internals

    private func loadState() -> AnnotationsLoadState {
        let path = annotationsFileURL.path
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: path) else {
            return .absent
        }
        // Symlink-rejecting load (settings-store pattern): anything that is
        // not a regular file is treated as corrupt — reads see an empty
        // document, and the first mutation renames the entry aside without
        // ever following it.
        guard attributes[.type] as? FileAttributeType == .typeRegular else {
            return .corrupt
        }
        let signature = AnnotationsFileSignature(
            byteCount: (attributes[.size] as? NSNumber)?.intValue ?? 0,
            modifiedAt: attributes[.modificationDate] as? Date ?? .distantPast
        )
        if let cached = ClipboardAnnotationsCache.shared.cachedState(path: path, signature: signature) {
            return cached
        }
        let state = parseFile()
        ClipboardAnnotationsCache.shared.store(path: path, signature: signature, state: state)
        return state
    }

    private func parseFile() -> AnnotationsLoadState {
        guard let data = try? Data(contentsOf: annotationsFileURL) else {
            return .corrupt
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let document = try? decoder.decode(ClipboardAnnotationsDocument.self, from: data) else {
            return .corrupt
        }
        if document.annotationsVersion > ClipboardAnnotationsDocument.currentVersion {
            return .newerFormat(document)
        }
        return .ok(document)
    }

    /// Every mutation funnels through here: read-only refusal, corrupt-file
    /// set-aside, default-record GC, atomic 0600 save, cache invalidation.
    /// A transform that changes nothing writes nothing (and never creates
    /// the file), so read-shaped call patterns leave no trace on disk.
    private func mutate(_ transform: (inout ClipboardAnnotationsDocument) -> Void) throws {
        let state = loadState()
        var document: ClipboardAnnotationsDocument
        var mustWrite = false
        switch state {
        case let .newerFormat(existing):
            throw ClipboardAnnotationsError.newerFormat(existing.annotationsVersion)
        case let .ok(existing):
            document = existing
        case .absent:
            document = ClipboardAnnotationsDocument(updatedAt: .distantPast)
        case .corrupt:
            try setAsideCorruptFile()
            document = ClipboardAnnotationsDocument(updatedAt: .distantPast)
            mustWrite = true
        }

        let before = document
        transform(&document)
        // Default-record GC: records that carry no information are dropped
        // on every save.
        document.annotations = document.annotations.filter { !$0.value.isDefault }
        guard mustWrite || document != before else {
            return
        }
        document.annotationsVersion = ClipboardAnnotationsDocument.currentVersion
        document.updatedAt = Date()
        try save(document)
    }

    private func setAsideCorruptFile() throws {
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        let asideURL = annotationsDirectoryURL.appendingPathComponent(
            "annotations.json.corrupt-\(formatter.string(from: Date()))"
        )
        // moveItem does not follow symlinks, so a symlinked annotations.json
        // is moved aside without touching its target.
        try FileManager.default.moveItem(at: annotationsFileURL, to: asideURL)
        ClipboardAnnotationsCache.shared.invalidate(path: annotationsFileURL.path)
    }

    private func save(_ document: ClipboardAnnotationsDocument) throws {
        try ClipboardPrivateFileSystem.createDirectory(
            annotationsDirectoryURL,
            archiveRoot: archiveRoot
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(document)
        let temporaryURL = annotationsDirectoryURL.appendingPathComponent(
            ".annotations.json.tmp-\(UUID().uuidString)"
        )
        try data.write(to: temporaryURL, options: [.atomic])
        try ClipboardPrivateFileSystem.secureFile(temporaryURL)
        _ = try FileManager.default.replaceItemAt(annotationsFileURL, withItemAt: temporaryURL)
        try ClipboardPrivateFileSystem.secureFile(annotationsFileURL)
        ClipboardAnnotationsCache.shared.invalidate(path: annotationsFileURL.path)
    }
}

/// Resolves the live occurrences of one content hash, newest first — the
/// shared lookup behind redactor annotation cleanup, the panel's
/// last-occurrence delete warning, and quick-picker snippet resolution.
///
/// Uses the derived index (`content_hash` column) when the index file
/// exists, post-filtered through the deletion ledger so a stale index can
/// never keep an annotation alive; falls back to ONE reader scan when the
/// index file is absent or the query fails.
public struct ClipboardOccurrenceResolver: Sendable {
    public var archiveRoot: URL
    public var indexURL: URL

    public init(archiveRoot: URL, indexURL: URL = ClipboardDefaults.indexURL()) {
        self.archiveRoot = archiveRoot
        self.indexURL = indexURL
    }

    /// `viaReaderScan: true` skips the index entirely and enumerates live
    /// occurrences from the archive files. Needed when the index cannot
    /// know the answer — e.g. re-indexing content whose rows were removed
    /// by a "restricted" override that is now being cleared (Slice 5).
    public func liveOccurrenceIDs(
        contentHash: String,
        viaReaderScan: Bool = false
    ) throws -> [String] {
        let suppression = try ClipboardSuppression(archiveRoot: archiveRoot).snapshot()
        if !viaReaderScan, FileManager.default.fileExists(atPath: indexURL.path) {
            let index = ClipboardDerivedIndex(archiveRoot: archiveRoot, indexURL: indexURL)
            if let ids = try? index.occurrenceIDs(contentHash: contentHash) {
                return ids.filter { !suppression.deletedIDs.contains($0) }
            }
        }

        // Index absent (or unreadable): one full reader scan.
        let reader = ClipboardArchiveReader(archiveRoot: archiveRoot)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        var matches: [(id: String, capturedAt: Date)] = []
        for fileURL in try reader.eventFiles() {
            let lines = try String(contentsOf: fileURL)
                .split(separator: "\n", omittingEmptySubsequences: true)
            for line in lines {
                guard let data = String(line).data(using: .utf8),
                      let event = try? decoder.decode(StoredClipboardEvent.self, from: data),
                      event.contentHash == contentHash,
                      !suppression.isSuppressed(event) else {
                    continue
                }
                matches.append((event.id, event.capturedAt))
            }
        }
        return matches
            .sorted { $0.capturedAt > $1.capturedAt }
            .map(\.id)
    }
}
