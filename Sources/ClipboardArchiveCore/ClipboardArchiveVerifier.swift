import Foundation

/// Everything `verify` found, whether or not any of it is a problem.
public struct ClipboardVerification: Sendable, Equatable {
    public var health: ClipboardArchiveHealth
    /// Events the archive holds that the index is supposed to hold too.
    public var eligibleEvents: Int
    public var indexedEvents: Int
    /// Eligible events with no row in the index.
    public var missingFromIndex: Int
    /// Index rows for events the archive no longer considers eligible —
    /// deleted, restricted, or gone.
    public var extraInIndex: Int
    /// False when the index database failed SQLite's own integrity check.
    public var indexIntegrityOK: Bool
    public var indexExists: Bool
    /// False when the index file is there but its rows could not be read,
    /// which is a different problem from having none of them.
    public var indexReadable: Bool
    public var settingsReadable: Bool
    public var pointerStatus: ClipboardStorePointerStatus

    /// One line per problem, in the order found. Empty means clean.
    public var problems: [String] {
        var found: [String] = []
        if !indexExists {
            found.append("There is no search index.")
        } else if !indexReadable {
            found.append("The search index is there but its rows could not be read.")
        } else if !indexIntegrityOK {
            found.append("The search index failed its integrity check.")
        }
        if indexReadable, missingFromIndex > 0 {
            found.append(
                missingFromIndex == 1
                    ? "1 stored clip is missing from the search index."
                    : "\(missingFromIndex) stored clips are missing from the search index."
            )
        }
        if extraInIndex > 0 {
            found.append(
                extraInIndex == 1
                    ? "1 search index row points at a clip the archive no longer has."
                    : "\(extraInIndex) search index rows point at clips the archive no longer has."
            )
        }
        if health.invalidJSONLines > 0 {
            found.append("\(health.invalidJSONLines) line\(health.invalidJSONLines == 1 ? "" : "s") in the archive could not be read.")
        }
        if health.missingBodyFiles > 0 {
            found.append("\(health.missingBodyFiles) clip\(health.missingBodyFiles == 1 ? "" : "s") reference a body file that is not there.")
        }
        if health.unsafeBodyPaths > 0 {
            found.append("\(health.unsafeBodyPaths) clip\(health.unsafeBodyPaths == 1 ? "" : "s") carry a body path that points outside the archive.")
        }
        if health.insecureFiles > 0 {
            found.append("\(health.insecureFiles) archive file\(health.insecureFiles == 1 ? " is" : "s are") readable by more than their owner.")
        }
        if health.orphanedRichBodyFiles > 0 {
            found.append("\(health.orphanedRichBodyFiles) body file\(health.orphanedRichBodyFiles == 1 ? " is" : "s are") referenced by no clip.")
        }
        if !settingsReadable {
            found.append("The settings file could not be read.")
        }
        if pointerStatus == .ignoredMissingPath || pointerStatus == .unreadable {
            found.append("The store pointer file cannot be trusted: \(pointerStatus.rawValue).")
        }
        return found
    }

    public var exit: ClipboardCLIExit {
        problems.isEmpty ? .success : .integrity
    }
}

/// The slow, complete check: what the archive holds, what the index holds,
/// and whether they agree.
public struct ClipboardArchiveVerifier: Sendable {
    public var archiveRoot: URL
    public var indexURL: URL
    /// Passed in rather than resolved here: a caller that named its stores
    /// on the command line must not have this reach past them for a
    /// settings file or a pointer belonging to somewhere else.
    public var settingsURL: URL
    public var pointerStatus: ClipboardStorePointerStatus

    public init(
        archiveRoot: URL,
        indexURL: URL,
        settingsURL: URL,
        pointerStatus: ClipboardStorePointerStatus
    ) {
        self.archiveRoot = archiveRoot
        self.indexURL = indexURL
        self.settingsURL = settingsURL
        self.pointerStatus = pointerStatus
    }

    /// The ids the index is supposed to hold: every stored event that is
    /// neither suppressed nor kept out of the index on purpose. Computed
    /// from the archive files themselves, through the same two predicates
    /// the index writer uses, so the comparison cannot be right for the
    /// wrong reason.
    public func eligibleEventIDs() throws -> Set<String> {
        let reader = ClipboardArchiveReader(archiveRoot: archiveRoot)
        let suppression = try ClipboardSuppression(archiveRoot: archiveRoot).snapshot()
        let restrictedHashes = ClipboardAnnotationsStore(archiveRoot: archiveRoot)
            .restrictedContentHashes()
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        var ids: Set<String> = []
        for fileURL in try reader.eventFiles() {
            let data = try Data(contentsOf: fileURL)
            for line in data.split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: true) {
                guard let event = try? decoder.decode(StoredClipboardEvent.self, from: line),
                      !suppression.isSuppressed(event) else {
                    continue
                }
                let override = restrictedHashes.contains(event.contentHash) ? "restricted" : nil
                if ClipboardSuppression.isIndexExcluded(event, sensitivityOverride: override) {
                    continue
                }
                ids.insert(event.id)
            }
        }
        return ids
    }

    public func verify() throws -> ClipboardVerification {
        let health = try ClipboardArchiveHealthReporter(
            archiveRoot: archiveRoot,
            indexURL: indexURL
        ).health()
        let index = ClipboardDerivedIndex(archiveRoot: archiveRoot, indexURL: indexURL)
        let indexExists = FileManager.default.fileExists(atPath: indexURL.path)
        let eligible = try eligibleEventIDs()
        let indexed = indexExists ? try? index.indexedEventIDs() : Set<String>()
        let settingsReadable = !FileManager.default.fileExists(atPath: settingsURL.path)
            || (try? Data(contentsOf: settingsURL)) != nil

        return ClipboardVerification(
            health: health,
            eligibleEvents: eligible.count,
            indexedEvents: indexed?.count ?? 0,
            missingFromIndex: eligible.subtracting(indexed ?? []).count,
            extraInIndex: (indexed ?? []).subtracting(eligible).count,
            indexIntegrityOK: indexExists && index.quickCheck(),
            indexExists: indexExists,
            indexReadable: indexed != nil,
            settingsReadable: settingsReadable,
            pointerStatus: pointerStatus
        )
    }
}
