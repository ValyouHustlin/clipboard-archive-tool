import CommonCrypto
import CryptoKit
import Foundation

// Slice 8: local encrypted backup/export (contracts 4/6/10).
// Container format v1 ("CLIPBAK1"):
//
//   "CLIPBAK1" (8 bytes)
//   formatVersion UInt32 LE = 1
//   kdfHeaderLen  UInt32 LE
//   kdfHeader JSON (PLAINTEXT: backupID, createdAt, kdf, iterations, salt,
//                   cipher, subkeyDerivation)
//   manifestBoxLen UInt64 LE
//   manifestBox   AES-256-GCM combined box, key = manifest subkey,
//                 AAD = the exact kdfHeader bytes as stored
//   then, per manifest entry, per 4 MiB chunk:
//   chunkBoxLen UInt32 LE
//   chunkBox    AES-256-GCM combined box, key = payload subkey,
//               AAD = "CLIPBAK1" + backupID (16 raw UUID bytes)
//                     + entryIndex UInt32 BE + chunkIndex UInt32 BE
//   EOF. Any trailing bytes are a hard error.
//
// Passphrase KDF: CommonCrypto PBKDF2-HMAC-SHA256, runtime-calibrated to
// ~250 ms with a hard floor of 600k iterations (lead decision recorded in
// docs/expansion-contracts.md contract 10). CryptoKit HKDF-SHA256 then
// derives the two domain-separated subkeys. Nothing hand-rolled.

public enum ClipboardBackupError: Error, Equatable, CustomStringConvertible, Sendable {
    case notABackupFile
    case unsupportedFormatVersion(UInt32)
    case malformedHeader
    case iterationsOutOfBounds(Int)
    /// Wrong passphrase and a tampered header/manifest are cryptographically
    /// indistinguishable (GCM authentication) — one error says exactly that.
    case authenticationFailed
    /// Structural or authentication failure AFTER the manifest verified —
    /// the payload was tampered with, truncated, or reordered. The string is
    /// a location tag (entry/chunk), never content.
    case corruptedPayload(String)
    case truncated
    case trailingData
    case entryPathRejected(String)
    case entryHashMismatch(String)
    case archiveNotEmpty
    case divergentBodyContent(String)
    case backupHasNoSettings
    case passphraseTooShort
    case keyDerivationFailed
    case fileChangedDuringExport(String)
    case ioFailure(String)

    public var description: String {
        switch self {
        case .notABackupFile:
            return "not a Clipboard Archive backup file"
        case let .unsupportedFormatVersion(version):
            return "backup format version \(version) is newer than this build supports"
        case .malformedHeader:
            return "backup header is malformed"
        case let .iterationsOutOfBounds(iterations):
            return "backup key-derivation iteration count \(iterations) is outside the accepted range"
        case .authenticationFailed:
            return "wrong passphrase, or the backup file is corrupted or was tampered with"
        case let .corruptedPayload(location):
            return "backup payload failed verification at \(location); the file is corrupted or was tampered with"
        case .truncated:
            return "backup file is truncated"
        case .trailingData:
            return "backup file has unexpected trailing data"
        case let .entryPathRejected(path):
            return "backup entry path rejected: \(path)"
        case let .entryHashMismatch(path):
            return "backup entry failed its integrity hash: \(path)"
        case .archiveNotEmpty:
            return "restore without --merge requires an empty archive (no event files, no deletion ledger, no annotations)"
        case let .divergentBodyContent(path):
            return "local file exists with different content (aborting whole import): \(path)"
        case .backupHasNoSettings:
            return "this backup does not include settings"
        case .passphraseTooShort:
            return "passphrase must be at least 8 characters"
        case .keyDerivationFailed:
            return "key derivation failed"
        case let .fileChangedDuringExport(path):
            return "file changed while the backup was being written: \(path)"
        case let .ioFailure(detail):
            return "backup io failure: \(detail)"
        }
    }
}

public enum ClipboardBackupFormat {
    public static let magic = Data("CLIPBAK1".utf8)
    public static let formatVersion: UInt32 = 1
    public static let chunkSize = 4 * 1024 * 1024
    public static let saltByteCount = 16
    public static let iterationFloor = 600_000
    public static let importIterationMinimum = 100_000
    public static let importIterationMaximum = 10_000_000
    public static let calibrationMilliseconds: UInt32 = 250
    public static let passphraseMinimumLength = 8
    public static let fileExtension = "clipbak"
    public static let settingsEntryPath = "meta/settings.json"

    static let manifestSubkeyInfo = "app.clipboardarchive.backup.v1.manifest"
    static let payloadSubkeyInfo = "app.clipboardarchive.backup.v1.payload"
    static let kdfName = "pbkdf2-hmac-sha256"
    static let cipherName = "aes-256-gcm"
    static let subkeyDerivationName = "hkdf-sha256"

    /// Hostile-header DoS bounds: declared lengths are checked against these
    /// caps BEFORE any allocation.
    static let headerLengthLimit = 16 * 1024
    static let manifestBoxLengthLimit = 64 * 1024 * 1024
    /// nonce (12) + tag (16) overhead of a combined AES-GCM box.
    static let boxOverhead = 28
    static let chunkBoxLengthLimit = chunkSize + boxOverhead

    /// PBKDF2 iteration count for a new export: runtime-calibrated to
    /// ~250 ms on this machine, never below the 600k floor.
    public static func calibratedIterations(passphraseLength: Int) -> Int {
        let rounds = CCCalibratePBKDF(
            CCPBKDFAlgorithm(kCCPBKDF2),
            max(passphraseLength, 1),
            saltByteCount,
            CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256),
            32,
            calibrationMilliseconds
        )
        return max(iterationFloor, Int(rounds))
    }

    /// Positional AAD binding every chunk to this backup, entry, and chunk
    /// index — drop, reorder, and cross-backup splice all fail decryption.
    static func chunkAAD(backupID: UUID, entryIndex: Int, chunkIndex: Int) -> Data {
        var aad = magic
        withUnsafeBytes(of: backupID.uuid) { aad.append(contentsOf: $0) }
        withUnsafeBytes(of: UInt32(entryIndex).bigEndian) { aad.append(contentsOf: $0) }
        withUnsafeBytes(of: UInt32(chunkIndex).bigEndian) { aad.append(contentsOf: $0) }
        return aad
    }
}

/// Best-effort in-memory zeroization for passphrase buffers. Swift gives no
/// hard guarantee against intermediate copies; error paths must still never
/// interpolate passphrase bytes into strings or logs.
public enum ClipboardBackupPassphrase {
    public static func zero(_ data: inout Data) {
        data.withUnsafeMutableBytes { raw in
            if let base = raw.baseAddress, raw.count > 0 {
                memset_s(base, raw.count, 0, raw.count)
            }
        }
        data.removeAll(keepingCapacity: false)
    }
}

/// Plaintext KDF header. Stored unencrypted (it is required to derive keys)
/// and authenticated after the fact by being the manifest box's AAD.
struct ClipboardBackupKDFHeader: Codable, Equatable {
    var backupID: String
    var createdAt: Date
    var kdf: String
    var iterations: Int
    var salt: String
    var cipher: String
    var subkeyDerivation: String
}

/// The sealed manifest: the single source of truth for the complete file
/// set. Because every entry (path, size, sha256, chunkCount) is inside the
/// authenticated manifest, dropping, truncating, reordering, or splicing
/// files from another backup is always detected.
public struct ClipboardBackupManifest: Codable, Equatable, Sendable {
    public struct Entry: Codable, Equatable, Sendable {
        public var path: String
        public var kind: String
        public var bytes: Int64
        public var sha256: String
        public var chunkCount: Int

        public init(path: String, kind: String, bytes: Int64, sha256: String, chunkCount: Int) {
            self.path = path
            self.kind = kind
            self.bytes = bytes
            self.sha256 = sha256
            self.chunkCount = chunkCount
        }
    }

    public struct Counts: Codable, Equatable, Sendable {
        public var storedEvents: Int
        public var blockedEvents: Int
        public var tombstoneEvents: Int
        public var ledgerRecords: Int
        public var bodyFiles: Int
        public var annotationRecords: Int
        public var collections: Int

        public init(
            storedEvents: Int = 0,
            blockedEvents: Int = 0,
            tombstoneEvents: Int = 0,
            ledgerRecords: Int = 0,
            bodyFiles: Int = 0,
            annotationRecords: Int = 0,
            collections: Int = 0
        ) {
            self.storedEvents = storedEvents
            self.blockedEvents = blockedEvents
            self.tombstoneEvents = tombstoneEvents
            self.ledgerRecords = ledgerRecords
            self.bodyFiles = bodyFiles
            self.annotationRecords = annotationRecords
            self.collections = collections
        }
    }

    public var manifestVersion: Int
    public var backupID: String
    public var createdAt: Date
    public var appVersion: String
    public var eventSchemaVersion: Int
    public var archiveFormatVersion: Int
    public var includesSettings: Bool
    public var counts: Counts
    public var earliestCapturedAt: Date?
    public var latestCapturedAt: Date?
    public var chunkSize: Int
    public var totalPlaintextBytes: Int64
    public var entries: [Entry]
    /// Non-allowlisted regular files found in the archive root, reported by
    /// name so layout drift fails loudly instead of silently dropping data.
    public var filesNotIncluded: [String]
}

// MARK: - Key derivation

struct ClipboardBackupKeys {
    var manifestKey: SymmetricKey
    var payloadKey: SymmetricKey

    init(passphrase: Data, salt: Data, iterations: Int) throws {
        var master = [UInt8](repeating: 0, count: 32)
        defer { memset_s(&master, master.count, 0, master.count) }
        var passphraseBytes = [UInt8](passphrase)
        defer { memset_s(&passphraseBytes, passphraseBytes.count, 0, passphraseBytes.count) }
        let passphraseCount = passphraseBytes.count
        if passphraseBytes.isEmpty {
            passphraseBytes = [0]
        }
        let saltBytes = [UInt8](salt)

        let status = passphraseBytes.withUnsafeBufferPointer { passBuffer -> Int32 in
            passBuffer.baseAddress!.withMemoryRebound(to: CChar.self, capacity: passphraseBytes.count) { passPointer in
                CCKeyDerivationPBKDF(
                    CCPBKDFAlgorithm(kCCPBKDF2),
                    passPointer,
                    passphraseCount,
                    saltBytes,
                    saltBytes.count,
                    CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256),
                    UInt32(iterations),
                    &master,
                    master.count
                )
            }
        }
        guard status == kCCSuccess else {
            throw ClipboardBackupError.keyDerivationFailed
        }

        let masterKey = SymmetricKey(data: Data(master))
        manifestKey = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: masterKey,
            info: Data(ClipboardBackupFormat.manifestSubkeyInfo.utf8),
            outputByteCount: 32
        )
        payloadKey = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: masterKey,
            info: Data(ClipboardBackupFormat.payloadSubkeyInfo.utf8),
            outputByteCount: 32
        )
    }
}

// MARK: - Archive enumeration (allowlist)

/// What one export/preview enumeration selected. Counts are computed HERE,
/// by the same code that selects files, so the manifest counts a preview
/// shows always agree with what the container actually holds.
public struct ClipboardBackupContents: Sendable {
    public struct File: Sendable {
        public var relativePath: String
        public var kind: String
        public var url: URL
        public var bytes: Int64
    }

    public var files: [File]
    public var notIncluded: [String]
    public var counts: ClipboardBackupManifest.Counts
    public var earliestCapturedAt: Date?
    public var latestCapturedAt: Date?
}

public struct ClipboardBackupEnumerator: Sendable {
    public var archiveRoot: URL

    public init(archiveRoot: URL) {
        self.archiveRoot = archiveRoot
    }

    /// Included (allowlist): raw/ (day NDJSON files + large-item bodies),
    /// deletion-ledger/, annotations/ (if present), manifests/ (historical
    /// daily manifests, not rebuildable), archive-format.json; optionally
    /// the settings file under the reserved container path meta/settings.json.
    /// Excluded: the derived SQLite index (rebuildable, and it could
    /// resurrect suppressed rows), lock files, staging directories, hidden
    /// files, symlinks. Non-allowlisted regular files are reported by name.
    public func enumerate(
        includeSettings: Bool = false,
        settingsURL: URL? = nil
    ) throws -> ClipboardBackupContents {
        let fileManager = FileManager.default
        var files: [ClipboardBackupContents.File] = []
        var notIncluded: [String] = []

        let allowedDirectories = ["raw", "deletion-ledger", "annotations", "manifests"]
        let allowedRootFiles = ["archive-format.json"]

        if fileManager.fileExists(atPath: archiveRoot.path) {
            let rootItems = try fileManager.contentsOfDirectory(
                at: archiveRoot,
                includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey],
                options: []
            ).sorted { $0.lastPathComponent < $1.lastPathComponent }

            for item in rootItems {
                let name = item.lastPathComponent
                if name.hasPrefix(".") {
                    continue // hidden: staging dirs, temp files — never included
                }
                let values = try item.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey])
                if values.isSymbolicLink == true {
                    notIncluded.append(name)
                    continue
                }
                if values.isDirectory == true {
                    if allowedDirectories.contains(name) {
                        try collectFiles(in: item, topLevel: name, into: &files, notIncluded: &notIncluded)
                    } else {
                        notIncluded.append(name + "/")
                    }
                } else if values.isRegularFile == true {
                    if allowedRootFiles.contains(name) {
                        files.append(.init(
                            relativePath: name,
                            kind: "format-marker",
                            url: item,
                            bytes: fileSize(item)
                        ))
                    } else {
                        notIncluded.append(name)
                    }
                }
            }
        }

        if includeSettings {
            let url = settingsURL ?? ClipboardDefaults.settingsURL()
            let attributes = try? fileManager.attributesOfItem(atPath: url.path)
            if attributes?[.type] as? FileAttributeType == .typeRegular {
                files.append(.init(
                    relativePath: ClipboardBackupFormat.settingsEntryPath,
                    kind: "settings",
                    url: url,
                    bytes: fileSize(url)
                ))
            }
        }

        files.sort { $0.relativePath < $1.relativePath }
        notIncluded.sort()

        let (counts, earliest, latest) = try computeCounts(files: files)
        return ClipboardBackupContents(
            files: files,
            notIncluded: notIncluded,
            counts: counts,
            earliestCapturedAt: earliest,
            latestCapturedAt: latest
        )
    }

    private func collectFiles(
        in directory: URL,
        topLevel: String,
        into files: inout [ClipboardBackupContents.File],
        notIncluded: inout [String]
    ) throws {
        let rootPath = archiveRoot.standardizedFileURL.path
        let urls = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles]
        )?.compactMap { $0 as? URL } ?? []

        for url in urls.sorted(by: { $0.path < $1.path }) {
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            let standardized = url.standardizedFileURL.path
            guard standardized.hasPrefix(rootPath + "/") else {
                continue
            }
            let relativePath = String(standardized.dropFirst(rootPath.count + 1))
            if values.isSymbolicLink == true {
                notIncluded.append(relativePath)
                continue
            }
            guard values.isRegularFile == true else {
                continue
            }
            // Every path re-validated through the shared containment check.
            guard (try? ClipboardArchivePath.containedURL(
                relativePath: relativePath,
                archiveRoot: archiveRoot
            )) != nil else {
                notIncluded.append(relativePath)
                continue
            }
            files.append(.init(
                relativePath: relativePath,
                kind: Self.kind(forRelativePath: relativePath, topLevel: topLevel),
                url: url,
                bytes: fileSize(url)
            ))
        }
    }

    static func kind(forRelativePath relativePath: String, topLevel: String) -> String {
        switch topLevel {
        case "raw":
            if relativePath.hasSuffix("_clipboard-events.ndjson") {
                return "events"
            }
            if relativePath.contains("_large-items/") {
                return "body"
            }
            return "raw-other"
        case "deletion-ledger":
            return "ledger"
        case "annotations":
            return relativePath == "annotations/annotations.json" ? "annotations" : "annotations-other"
        case "manifests":
            return "manifest"
        default:
            return "other"
        }
    }

    private func computeCounts(
        files: [ClipboardBackupContents.File]
    ) throws -> (ClipboardBackupManifest.Counts, Date?, Date?) {
        var counts = ClipboardBackupManifest.Counts()
        var earliest: Date?
        var latest: Date?
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        for file in files {
            switch file.kind {
            case "events":
                let lines = try String(contentsOf: file.url)
                    .split(separator: "\n", omittingEmptySubsequences: true)
                for line in lines {
                    guard let data = String(line).data(using: .utf8) else {
                        continue
                    }
                    if let event = try? decoder.decode(StoredClipboardEvent.self, from: data) {
                        if event.privacyLabel == .doNotIndex {
                            counts.tombstoneEvents += 1
                        } else {
                            counts.storedEvents += 1
                            if earliest == nil || event.capturedAt < earliest! {
                                earliest = event.capturedAt
                            }
                            if latest == nil || event.capturedAt > latest! {
                                latest = event.capturedAt
                            }
                        }
                    } else if let blocked = try? decoder.decode(BlockedClipboardEvent.self, from: data),
                              blocked.eventType == "blocked_sensitive_clipboard_item" {
                        counts.blockedEvents += 1
                    }
                }
            case "body":
                counts.bodyFiles += 1
            case "ledger":
                let lines = try String(contentsOf: file.url)
                    .split(separator: "\n", omittingEmptySubsequences: true)
                for line in lines {
                    guard let data = String(line).data(using: .utf8),
                          (try? decoder.decode(ClipboardDeletionEvent.self, from: data)) != nil else {
                        continue
                    }
                    counts.ledgerRecords += 1
                }
            case "annotations":
                if let data = try? Data(contentsOf: file.url),
                   let document = try? decoder.decode(ClipboardAnnotationsDocument.self, from: data) {
                    counts.annotationRecords += document.annotations.count
                    counts.collections += document.collections.count
                }
            default:
                break
            }
        }
        return (counts, earliest, latest)
    }

    private func fileSize(_ url: URL) -> Int64 {
        let values = try? url.resourceValues(forKeys: [.fileSizeKey])
        return Int64(values?.fileSize ?? 0)
    }
}

// MARK: - Streaming SHA-256

enum ClipboardBackupHashing {
    /// Streams a file through SHA-256 in chunk-sized reads, optionally
    /// stopping after `limitBytes` (used so a day file that gained appended
    /// lines mid-export still hashes to the recorded prefix). Never loads a
    /// whole body into memory.
    static func sha256OfFile(at url: URL, limitBytes: Int64? = nil) throws -> (hash: String, bytes: Int64) {
        guard let handle = try? FileHandle(forReadingFrom: url) else {
            throw ClipboardBackupError.ioFailure("cannot open for reading: \(url.lastPathComponent)")
        }
        defer { try? handle.close() }
        var hasher = SHA256()
        var total: Int64 = 0
        while true {
            var wanted = ClipboardBackupFormat.chunkSize
            if let limitBytes {
                let remaining = limitBytes - total
                if remaining <= 0 {
                    break
                }
                wanted = min(wanted, Int(remaining))
            }
            // FileHandle reads return autoreleased buffers; without a pool
            // per chunk the whole file accumulates in memory.
            let consumed = try autoreleasepool { () -> Int in
                guard let data = try handle.read(upToCount: wanted), !data.isEmpty else {
                    return 0
                }
                hasher.update(data: data)
                return data.count
            }
            if consumed == 0 {
                break
            }
            total += Int64(consumed)
        }
        let digest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        return ("sha256:" + digest, total)
    }

    static func sha256(of data: Data) -> String {
        "sha256:" + SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

// MARK: - Exporter

public struct ClipboardBackupExporter: Sendable {
    public var archiveRoot: URL

    public init(archiveRoot: URL) {
        self.archiveRoot = archiveRoot
    }

    public struct Result: Sendable {
        public var manifest: ClipboardBackupManifest
        public var outputURL: URL
        public var containerBytes: Int64
        public var iterations: Int
    }

    /// Two passes: (1) walk + hash builds the manifest, (2) stream + seal
    /// writes the container. Memory stays bounded to ~one 4 MiB chunk.
    /// The partial file is created 0600, fsynced, then atomically renamed.
    ///
    /// `iterationsOverride` exists for tests only (still bounded by the
    /// import range); production callers pass nil and get the calibrated
    /// count with the 600k floor.
    public func export(
        to destination: URL,
        passphrase: Data,
        includeSettings: Bool = false,
        settingsURL: URL? = nil,
        iterationsOverride: Int? = nil,
        progress: (@Sendable (Int64, Int64) -> Void)? = nil
    ) throws -> Result {
        guard passphrase.count >= ClipboardBackupFormat.passphraseMinimumLength else {
            throw ClipboardBackupError.passphraseTooShort
        }

        // Pass 1: enumerate + hash.
        let contents = try ClipboardBackupEnumerator(archiveRoot: archiveRoot)
            .enumerate(includeSettings: includeSettings, settingsURL: settingsURL)
        var entries: [ClipboardBackupManifest.Entry] = []
        var totalPlaintext: Int64 = 0
        for file in contents.files {
            let (hash, bytes) = try ClipboardBackupHashing.sha256OfFile(at: file.url)
            let chunkCount = Self.chunkCount(forBytes: bytes)
            entries.append(.init(
                path: file.relativePath,
                kind: file.kind,
                bytes: bytes,
                sha256: hash,
                chunkCount: chunkCount
            ))
            totalPlaintext += bytes
        }

        let backupID = UUID()
        let createdAt = Date()
        let iterations = iterationsOverride
            ?? ClipboardBackupFormat.calibratedIterations(passphraseLength: passphrase.count)
        // 16 random salt bytes from CryptoKit's CSPRNG.
        let salt = SymmetricKey(size: .bits128).withUnsafeBytes { Data($0) }

        let header = ClipboardBackupKDFHeader(
            backupID: backupID.uuidString,
            createdAt: createdAt,
            kdf: ClipboardBackupFormat.kdfName,
            iterations: iterations,
            salt: salt.base64EncodedString(),
            cipher: ClipboardBackupFormat.cipherName,
            subkeyDerivation: ClipboardBackupFormat.subkeyDerivationName
        )
        let manifest = ClipboardBackupManifest(
            manifestVersion: 1,
            backupID: backupID.uuidString,
            createdAt: createdAt,
            appVersion: Self.appVersion(),
            eventSchemaVersion: StoredClipboardEvent.currentSchemaVersion,
            archiveFormatVersion: 1,
            includesSettings: contents.files.contains { $0.kind == "settings" },
            counts: contents.counts,
            earliestCapturedAt: contents.earliestCapturedAt,
            latestCapturedAt: contents.latestCapturedAt,
            chunkSize: ClipboardBackupFormat.chunkSize,
            totalPlaintextBytes: totalPlaintext,
            entries: entries,
            filesNotIncluded: contents.notIncluded
        )

        let keys = try ClipboardBackupKeys(passphrase: passphrase, salt: salt, iterations: iterations)

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let headerData = try encoder.encode(header)
        let manifestData = try encoder.encode(manifest)
        let manifestBox = try AES.GCM.seal(
            manifestData,
            using: keys.manifestKey,
            authenticating: headerData
        ).combined!

        // Pass 2: stream + seal into a 0600-at-creation partial file.
        let partialURL = destination
            .deletingLastPathComponent()
            .appendingPathComponent(".partial-\(UUID().uuidString)")
        guard FileManager.default.createFile(
            atPath: partialURL.path,
            contents: nil,
            attributes: [.posixPermissions: NSNumber(value: Int16(0o600))]
        ) else {
            throw ClipboardBackupError.ioFailure("cannot create output file")
        }
        var succeeded = false
        defer {
            if !succeeded {
                try? FileManager.default.removeItem(at: partialURL)
            }
        }
        let output = try FileHandle(forWritingTo: partialURL)
        defer { try? output.close() }

        try output.write(contentsOf: ClipboardBackupFormat.magic)
        try output.write(contentsOf: Self.uint32LE(ClipboardBackupFormat.formatVersion))
        try output.write(contentsOf: Self.uint32LE(UInt32(headerData.count)))
        try output.write(contentsOf: headerData)
        try output.write(contentsOf: Self.uint64LE(UInt64(manifestBox.count)))
        try output.write(contentsOf: manifestBox)

        var processed: Int64 = 0
        for (entryIndex, file) in contents.files.enumerated() {
            let entry = entries[entryIndex]
            guard let input = try? FileHandle(forReadingFrom: file.url) else {
                throw ClipboardBackupError.ioFailure("cannot open for reading: \(entry.path)")
            }
            defer { try? input.close() }

            var hasher = SHA256()
            var remaining = entry.bytes
            var chunkIndex = 0
            while remaining > 0 {
                let wanted = Int(min(Int64(ClipboardBackupFormat.chunkSize), remaining))
                // One pool per chunk keeps memory bounded to ~one chunk
                // regardless of body size (autoreleased read buffers).
                let consumed = try autoreleasepool { () -> Int in
                    guard let chunk = try input.read(upToCount: wanted), !chunk.isEmpty else {
                        throw ClipboardBackupError.fileChangedDuringExport(entry.path)
                    }
                    hasher.update(data: chunk)
                    let box = try AES.GCM.seal(
                        chunk,
                        using: keys.payloadKey,
                        nonce: AES.GCM.Nonce(),
                        authenticating: ClipboardBackupFormat.chunkAAD(
                            backupID: backupID,
                            entryIndex: entryIndex,
                            chunkIndex: chunkIndex
                        )
                    ).combined!
                    try output.write(contentsOf: Self.uint32LE(UInt32(box.count)))
                    try output.write(contentsOf: box)
                    return chunk.count
                }
                remaining -= Int64(consumed)
                processed += Int64(consumed)
                chunkIndex += 1
                progress?(processed, totalPlaintext)
            }
            // A file that shrank or was rewritten between the hashing pass
            // and the sealing pass would silently produce a container whose
            // manifest lies. Appends past the recorded size are fine (we
            // read exactly entry.bytes); anything else aborts the export.
            let streamedHash = "sha256:" + hasher.finalize().map { String(format: "%02x", $0) }.joined()
            guard chunkIndex == entry.chunkCount, streamedHash == entry.sha256 else {
                throw ClipboardBackupError.fileChangedDuringExport(entry.path)
            }
        }

        try output.synchronize()
        try output.close()

        // Atomic rename over the destination (rename(2) replaces atomically).
        let renameResult = partialURL.withUnsafeFileSystemRepresentation { source in
            destination.withUnsafeFileSystemRepresentation { target in
                rename(source!, target!)
            }
        }
        guard renameResult == 0 else {
            throw ClipboardBackupError.ioFailure("atomic rename failed")
        }
        succeeded = true

        let containerBytes = (try? destination.resourceValues(forKeys: [.fileSizeKey]).fileSize)
            .map(Int64.init) ?? 0
        return Result(
            manifest: manifest,
            outputURL: destination,
            containerBytes: containerBytes,
            iterations: iterations
        )
    }

    static func chunkCount(forBytes bytes: Int64) -> Int {
        guard bytes > 0 else {
            return 0
        }
        let size = Int64(ClipboardBackupFormat.chunkSize)
        return Int((bytes + size - 1) / size)
    }

    static func appVersion() -> String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String
        return version ?? "development"
    }

    static func uint32LE(_ value: UInt32) -> Data {
        withUnsafeBytes(of: value.littleEndian) { Data($0) }
    }

    static func uint64LE(_ value: UInt64) -> Data {
        withUnsafeBytes(of: value.littleEndian) { Data($0) }
    }
}

// MARK: - Container reading (shared by inspect and import staging)

struct ClipboardBackupContainerReader {
    let fileURL: URL
    let handle: FileHandle
    let headerData: Data
    let header: ClipboardBackupKDFHeader
    let backupID: UUID
    let salt: Data
    /// File offset of the first chunk box (right after the manifest box).
    let payloadOffset: UInt64
    let manifestBoxData: Data

    init(fileURL: URL) throws {
        self.fileURL = fileURL
        guard let handle = try? FileHandle(forReadingFrom: fileURL) else {
            throw ClipboardBackupError.ioFailure("cannot open backup file")
        }
        self.handle = handle

        func readExactly(_ count: Int) throws -> Data {
            guard let data = try handle.read(upToCount: count), data.count == count else {
                throw ClipboardBackupError.truncated
            }
            return data
        }

        let magic = try? handle.read(upToCount: ClipboardBackupFormat.magic.count)
        guard let magic, magic.count == ClipboardBackupFormat.magic.count else {
            throw ClipboardBackupError.notABackupFile
        }
        guard magic == ClipboardBackupFormat.magic else {
            throw ClipboardBackupError.notABackupFile
        }

        let version = Self.uint32LE(try readExactly(4))
        guard version == ClipboardBackupFormat.formatVersion else {
            throw ClipboardBackupError.unsupportedFormatVersion(version)
        }

        let headerLength = Int(Self.uint32LE(try readExactly(4)))
        guard headerLength > 0, headerLength <= ClipboardBackupFormat.headerLengthLimit else {
            throw ClipboardBackupError.malformedHeader
        }
        headerData = try readExactly(headerLength)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let parsed = try? decoder.decode(ClipboardBackupKDFHeader.self, from: headerData) else {
            throw ClipboardBackupError.malformedHeader
        }
        header = parsed
        guard header.kdf == ClipboardBackupFormat.kdfName,
              header.cipher == ClipboardBackupFormat.cipherName,
              header.subkeyDerivation == ClipboardBackupFormat.subkeyDerivationName,
              let parsedID = UUID(uuidString: header.backupID),
              let parsedSalt = Data(base64Encoded: header.salt),
              parsedSalt.count == ClipboardBackupFormat.saltByteCount else {
            throw ClipboardBackupError.malformedHeader
        }
        backupID = parsedID
        salt = parsedSalt
        guard header.iterations >= ClipboardBackupFormat.importIterationMinimum,
              header.iterations <= ClipboardBackupFormat.importIterationMaximum else {
            throw ClipboardBackupError.iterationsOutOfBounds(header.iterations)
        }

        let manifestBoxLength = Self.uint64LE(try readExactly(8))
        guard manifestBoxLength >= UInt64(ClipboardBackupFormat.boxOverhead),
              manifestBoxLength <= UInt64(ClipboardBackupFormat.manifestBoxLengthLimit) else {
            throw ClipboardBackupError.malformedHeader
        }
        manifestBoxData = try readExactly(Int(manifestBoxLength))
        payloadOffset = try handle.offset()
    }

    func deriveKeys(passphrase: Data) throws -> ClipboardBackupKeys {
        try ClipboardBackupKeys(passphrase: passphrase, salt: salt, iterations: header.iterations)
    }

    /// Opens the sealed manifest. Wrong passphrase and header/manifest
    /// tamper both surface as `.authenticationFailed`, deliberately
    /// indistinguishable.
    func openManifest(keys: ClipboardBackupKeys) throws -> ClipboardBackupManifest {
        guard let box = try? AES.GCM.SealedBox(combined: manifestBoxData),
              let plaintext = try? AES.GCM.open(box, using: keys.manifestKey, authenticating: headerData) else {
            throw ClipboardBackupError.authenticationFailed
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let manifest = try? decoder.decode(ClipboardBackupManifest.self, from: plaintext) else {
            throw ClipboardBackupError.authenticationFailed
        }
        guard manifest.backupID == header.backupID,
              manifest.chunkSize == ClipboardBackupFormat.chunkSize else {
            throw ClipboardBackupError.authenticationFailed
        }
        for entry in manifest.entries {
            guard entry.bytes >= 0,
                  entry.chunkCount == ClipboardBackupExporter.chunkCount(forBytes: entry.bytes) else {
                throw ClipboardBackupError.corruptedPayload("entry \(entry.path)")
            }
        }
        return manifest
    }

    /// Walks every chunk box after the manifest. `open` nil = structural
    /// walk only (lengths + exact EOF); non-nil = decrypt and hand each
    /// plaintext chunk to the caller.
    func walkChunks(
        manifest: ClipboardBackupManifest,
        keys: ClipboardBackupKeys?,
        chunkHandler: ((_ entryIndex: Int, _ chunkIndex: Int, _ plaintext: Data) throws -> Void)?
    ) throws {
        try handle.seek(toOffset: payloadOffset)

        func readExactly(_ count: Int) throws -> Data {
            guard let data = try handle.read(upToCount: count), data.count == count else {
                throw ClipboardBackupError.truncated
            }
            return data
        }

        for (entryIndex, entry) in manifest.entries.enumerated() {
            var remaining = entry.bytes
            for chunkIndex in 0..<entry.chunkCount {
                try autoreleasepool {
                    let boxLength = Int(Self.uint32LE(try readExactly(4)))
                    guard boxLength >= ClipboardBackupFormat.boxOverhead,
                          boxLength <= ClipboardBackupFormat.chunkBoxLengthLimit else {
                        throw ClipboardBackupError.corruptedPayload("entry \(entryIndex) chunk \(chunkIndex)")
                    }
                    let expectedPlain = Int(min(Int64(ClipboardBackupFormat.chunkSize), remaining))
                    guard boxLength == expectedPlain + ClipboardBackupFormat.boxOverhead else {
                        throw ClipboardBackupError.corruptedPayload("entry \(entryIndex) chunk \(chunkIndex)")
                    }
                    let boxData = try readExactly(boxLength)
                    if let keys, let chunkHandler {
                        guard let box = try? AES.GCM.SealedBox(combined: boxData),
                              let plaintext = try? AES.GCM.open(
                                box,
                                using: keys.payloadKey,
                                authenticating: ClipboardBackupFormat.chunkAAD(
                                    backupID: backupID,
                                    entryIndex: entryIndex,
                                    chunkIndex: chunkIndex
                                )
                              ) else {
                            throw ClipboardBackupError.corruptedPayload("entry \(entryIndex) chunk \(chunkIndex)")
                        }
                        try chunkHandler(entryIndex, chunkIndex, plaintext)
                    }
                    remaining -= Int64(expectedPlain)
                }
            }
        }

        // Exact EOF required: trailing bytes are a hard error.
        if let extra = try handle.read(upToCount: 1), !extra.isEmpty {
            throw ClipboardBackupError.trailingData
        }
    }

    func close() {
        try? handle.close()
    }

    static func uint32LE(_ data: Data) -> UInt32 {
        data.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }.littleEndian
    }

    static func uint64LE(_ data: Data) -> UInt64 {
        data.withUnsafeBytes { $0.loadUnaligned(as: UInt64.self) }.littleEndian
    }
}

// MARK: - Inspector

public struct ClipboardBackupInspection: Sendable {
    public var manifest: ClipboardBackupManifest
    public var iterations: Int
    public var containerBytes: Int64
    /// True when the chunk framing walked to exact EOF (lengths only; chunk
    /// authenticity is proven at restore staging, not here).
    public var framingIntact: Bool
}

public enum ClipboardBackupInspector {
    /// Decrypts ONLY the manifest (preview requires the passphrase because
    /// counts and date ranges are themselves sensitive), then walks the
    /// chunk framing structurally to exact EOF.
    public static func inspect(fileURL: URL, passphrase: Data) throws -> ClipboardBackupInspection {
        let reader = try ClipboardBackupContainerReader(fileURL: fileURL)
        defer { reader.close() }
        let keys = try reader.deriveKeys(passphrase: passphrase)
        let manifest = try reader.openManifest(keys: keys)
        try reader.walkChunks(manifest: manifest, keys: nil, chunkHandler: nil)
        let containerBytes = (try? fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize)
            .map(Int64.init) ?? 0
        return ClipboardBackupInspection(
            manifest: manifest,
            iterations: reader.header.iterations,
            containerBytes: containerBytes,
            framingIntact: true
        )
    }
}
