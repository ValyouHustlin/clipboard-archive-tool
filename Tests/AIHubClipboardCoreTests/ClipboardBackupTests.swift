import CryptoKit
import Foundation
import Testing
@testable import ClipboardArchiveCore

/// Shared synthetic-fixture helpers for the Slice 8 backup tests. Every
/// byte is authored test data under isolated temp roots (contract 10);
/// nothing touches a live archive. Tests use a low (but import-legal)
/// PBKDF2 iteration count so the suite stays fast; the calibrated-floor
/// default is asserted separately.
enum BackupTestSupport {
    static let passphrase = Data("correct-horse-battery".utf8)
    static let wrongPassphrase = Data("wrong-horse-battery".utf8)
    static let testIterations = 100_000

    static func temporaryDirectory(_ label: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("clipboard-backup-tests-\(label)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func seedEvent(
        _ archiveRoot: URL,
        content: String,
        minutesAgo: Double = 30,
        inlineLimit: Int = 64 * 1024
    ) throws -> StoredClipboardEvent {
        let writer = ClipboardArchiveWriter(archiveRoot: archiveRoot, inlineContentLimitBytes: inlineLimit)
        return try writer.archiveAllowedCapture(ClipboardCapture(
            capturedAt: Date().addingTimeInterval(-minutesAgo * 60),
            content: content,
            sourceApp: ClipboardSourceApp(name: "Notes", bundleIdentifier: "com.apple.Notes"),
            pasteboardTypes: ["public.utf8-plain-text"]
        ))
    }

    /// A fully mixed archive: inline events, one large body, a blocked
    /// line, a tombstone + ledger record (via the redactor), annotations
    /// with a collection, one historical manifest file, and the format
    /// marker (written by the writer).
    @discardableResult
    static func seedMixedArchive(
        _ archiveRoot: URL,
        indexURL: URL
    ) throws -> (events: [StoredClipboardEvent], redactedID: String) {
        var events: [StoredClipboardEvent] = []
        events.append(try seedEvent(archiveRoot, content: "synthetic backup fixture alpha", minutesAgo: 400))
        events.append(try seedEvent(archiveRoot, content: "synthetic backup fixture beta", minutesAgo: 300))
        let bigBody = String(repeating: "large-body-line synthetic fixture\n", count: 4000)
        events.append(try seedEvent(archiveRoot, content: bigBody, minutesAgo: 200, inlineLimit: 128))
        let doomed = try seedEvent(archiveRoot, content: "synthetic fixture to redact", minutesAgo: 100)
        events.append(doomed)

        let writer = ClipboardArchiveWriter(archiveRoot: archiveRoot)
        try writer.archiveBlockedCapture(
            ClipboardCapture(
                capturedAt: Date().addingTimeInterval(-90 * 60),
                content: "never stored",
                sourceApp: ClipboardSourceApp(name: "Dashlane", bundleIdentifier: "com.dashlane.dashlane")
            ),
            reason: "source_app_denylist:dashlane"
        )

        _ = try ClipboardArchiveRedactor(archiveRoot: archiveRoot, indexURL: indexURL)
            .redact(eventID: doomed.id)

        let annotations = ClipboardAnnotationsStore(archiveRoot: archiveRoot)
        try annotations.setPinned(true, forContentHash: events[0].contentHash)
        try annotations.setTags(["fixtures", "alpha"], forContentHash: events[0].contentHash)
        let collection = try annotations.createCollection(named: "Fixture Collection")
        try annotations.setMembership(
            contentHash: events[0].contentHash,
            inCollection: collection.id,
            isMember: true
        )

        let manifestsDirectory = archiveRoot.appendingPathComponent("manifests", isDirectory: true)
        try FileManager.default.createDirectory(
            at: manifestsDirectory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: NSNumber(value: Int16(0o700))]
        )
        let manifestFile = manifestsDirectory.appendingPathComponent("2026-07-30_manifest.json")
        try Data("{\"synthetic\":\"daily manifest fixture\"}\n".utf8)
            .write(to: manifestFile, options: [.atomic])
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: Int16(0o600))],
            ofItemAtPath: manifestFile.path
        )

        return (events, doomed.id)
    }

    /// Map of relative path -> "sha256hex:posixPerm" over every regular
    /// non-hidden file. The byte-identical-tree assertion currency.
    static func treeSignature(_ root: URL) throws -> [String: String] {
        var signature: [String: String] = [:]
        guard FileManager.default.fileExists(atPath: root.path) else {
            return signature
        }
        let rootPath = root.standardizedFileURL.path
        let urls = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        )?.compactMap { $0 as? URL } ?? []
        for url in urls {
            let values = try url.resourceValues(forKeys: [.isRegularFileKey])
            guard values.isRegularFile == true else {
                continue
            }
            let relative = String(url.standardizedFileURL.path.dropFirst(rootPath.count + 1))
            let data = try Data(contentsOf: url)
            let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            let perm = (attributes[.posixPermissions] as? NSNumber)?.int16Value ?? 0
            signature[relative] = "\(hash):\(String(perm, radix: 8))"
        }
        return signature
    }

    static func stagingDirectories(_ root: URL) -> [String] {
        let items = (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []
        return items.filter { $0.hasPrefix(".backup-staging-") }
    }

    static func export(
        _ archiveRoot: URL,
        to destination: URL,
        passphrase: Data = passphrase,
        includeSettings: Bool = false,
        settingsURL: URL? = nil
    ) throws -> ClipboardBackupExporter.Result {
        try ClipboardBackupExporter(archiveRoot: archiveRoot).export(
            to: destination,
            passphrase: passphrase,
            includeSettings: includeSettings,
            settingsURL: settingsURL,
            iterationsOverride: testIterations
        )
    }

    static func copyTree(_ source: URL, to target: URL) throws {
        if FileManager.default.fileExists(atPath: target.path) {
            try FileManager.default.removeItem(at: target)
        }
        try FileManager.default.copyItem(at: source, to: target)
    }

    // MARK: - Container surgery helpers (tamper matrix)

    struct ContainerLayout {
        var headerOffset: Int
        var headerLength: Int
        var manifestBoxOffset: Int
        var manifestBoxLength: Int
        var firstChunkOffset: Int
    }

    static func layout(of container: Data) -> ContainerLayout {
        let headerLength = Int(readUInt32LE(container, at: 12))
        let headerOffset = 16
        let manifestLengthOffset = headerOffset + headerLength
        let manifestBoxLength = Int(readUInt64LE(container, at: manifestLengthOffset))
        let manifestBoxOffset = manifestLengthOffset + 8
        return ContainerLayout(
            headerOffset: headerOffset,
            headerLength: headerLength,
            manifestBoxOffset: manifestBoxOffset,
            manifestBoxLength: manifestBoxLength,
            firstChunkOffset: manifestBoxOffset + manifestBoxLength
        )
    }

    static func readUInt32LE(_ data: Data, at offset: Int) -> UInt32 {
        data.subdata(in: offset..<(offset + 4)).withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }.littleEndian
    }

    static func readUInt64LE(_ data: Data, at offset: Int) -> UInt64 {
        data.subdata(in: offset..<(offset + 8)).withUnsafeBytes { $0.loadUnaligned(as: UInt64.self) }.littleEndian
    }

    static func flippingByte(_ data: Data, at offset: Int) -> Data {
        var copy = data
        copy[offset] ^= 0xFF
        return copy
    }

    /// Rebuilds a container around a modified plaintext KDF header (bounds
    /// tests). The manifest box is left as-is: header-bounds checks must
    /// fire BEFORE any decryption is attempted.
    static func replacingHeader(_ container: Data, transform: (inout [String: Any]) -> Void) throws -> Data {
        let layout = layout(of: container)
        let headerData = container.subdata(in: layout.headerOffset..<(layout.headerOffset + layout.headerLength))
        var json = try JSONSerialization.jsonObject(with: headerData) as? [String: Any] ?? [:]
        transform(&json)
        let newHeader = try JSONSerialization.data(withJSONObject: json, options: [.sortedKeys])
        var rebuilt = Data()
        rebuilt.append(container.subdata(in: 0..<12))
        rebuilt.append(ClipboardBackupExporter.uint32LE(UInt32(newHeader.count)))
        rebuilt.append(newHeader)
        rebuilt.append(container.subdata(in: (layout.headerOffset + layout.headerLength)..<container.count))
        return rebuilt
    }
}

@Suite("Clipboard Backup Format", .serialized)
struct ClipboardBackupTests {
    // MARK: - Round trips

    @Test func emptyArchiveRoundTripsToEmptyTree() throws {
        let source = try BackupTestSupport.temporaryDirectory("empty-src")
        let restored = try BackupTestSupport.temporaryDirectory("empty-dst")
        let backupFile = try BackupTestSupport.temporaryDirectory("empty-out")
            .appendingPathComponent("empty.clipbak")

        let result = try BackupTestSupport.export(source, to: backupFile)
        #expect(result.manifest.entries.isEmpty)
        #expect(result.manifest.counts.storedEvents == 0)

        let importer = ClipboardBackupImporter(
            archiveRoot: restored,
            indexURL: try BackupTestSupport.temporaryDirectory("empty-idx").appendingPathComponent("index.sqlite")
        )
        let outcome = try importer.run(
            backupFileURL: backupFile,
            passphrase: BackupTestSupport.passphrase,
            options: ClipboardBackupImportOptions(merge: false),
            dryRun: false
        )
        #expect(outcome.plan.newEvents == 0)
        #expect(try BackupTestSupport.treeSignature(restored).isEmpty)
        #expect(BackupTestSupport.stagingDirectories(restored).isEmpty)
    }

    @Test func mixedArchiveRoundTripIsByteIdentical() throws {
        let source = try BackupTestSupport.temporaryDirectory("mixed-src")
        let sourceIndex = try BackupTestSupport.temporaryDirectory("mixed-src-idx")
            .appendingPathComponent("index.sqlite")
        try BackupTestSupport.seedMixedArchive(source, indexURL: sourceIndex)
        let backupFile = try BackupTestSupport.temporaryDirectory("mixed-out")
            .appendingPathComponent("mixed.clipbak")
        let restored = try BackupTestSupport.temporaryDirectory("mixed-dst")

        let result = try BackupTestSupport.export(source, to: backupFile)
        #expect(result.manifest.counts.storedEvents == 3)
        #expect(result.manifest.counts.tombstoneEvents == 1)
        #expect(result.manifest.counts.blockedEvents == 1)
        #expect(result.manifest.counts.ledgerRecords == 1)
        #expect(result.manifest.counts.bodyFiles == 1)
        #expect(result.manifest.counts.annotationRecords == 1)
        #expect(result.manifest.counts.collections == 1)
        #expect(result.manifest.filesNotIncluded.isEmpty)

        // Backup container itself is owner-only.
        let containerPerm = (try FileManager.default.attributesOfItem(atPath: backupFile.path)[.posixPermissions] as? NSNumber)?.int16Value
        #expect(containerPerm == 0o600)

        let importer = ClipboardBackupImporter(
            archiveRoot: restored,
            indexURL: try BackupTestSupport.temporaryDirectory("mixed-dst-idx").appendingPathComponent("index.sqlite")
        )
        let outcome = try importer.run(
            backupFileURL: backupFile,
            passphrase: BackupTestSupport.passphrase,
            options: ClipboardBackupImportOptions(merge: false),
            dryRun: false
        )
        #expect(outcome.plan.mode == "restore-empty")
        #expect(outcome.indexRebuildFailed == false)

        let sourceTree = try BackupTestSupport.treeSignature(source)
        let restoredTree = try BackupTestSupport.treeSignature(restored)
        #expect(sourceTree == restoredTree)
        #expect(!sourceTree.isEmpty)

        // Restored directories are 0700.
        let rawDirectory = restored.appendingPathComponent("raw")
        let rawPerm = (try FileManager.default.attributesOfItem(atPath: rawDirectory.path)[.posixPermissions] as? NSNumber)?.int16Value
        #expect(rawPerm == 0o700)
    }

    @Test func multiChunkBodyRoundTrips() throws {
        let source = try BackupTestSupport.temporaryDirectory("chunks-src")
        // 9 MiB body -> 3 chunks (4 + 4 + 1).
        let body = String(repeating: "abcdefgh", count: 9 * 1024 * 1024 / 8)
        _ = try BackupTestSupport.seedEvent(source, content: body, inlineLimit: 1024)
        let backupFile = try BackupTestSupport.temporaryDirectory("chunks-out")
            .appendingPathComponent("chunks.clipbak")
        let restored = try BackupTestSupport.temporaryDirectory("chunks-dst")

        let result = try BackupTestSupport.export(source, to: backupFile)
        let bodyEntry = try #require(result.manifest.entries.first { $0.kind == "body" })
        #expect(bodyEntry.chunkCount == 3)

        let importer = ClipboardBackupImporter(
            archiveRoot: restored,
            indexURL: try BackupTestSupport.temporaryDirectory("chunks-idx").appendingPathComponent("index.sqlite")
        )
        _ = try importer.run(
            backupFileURL: backupFile,
            passphrase: BackupTestSupport.passphrase,
            options: ClipboardBackupImportOptions(merge: false),
            dryRun: false
        )
        #expect(try BackupTestSupport.treeSignature(source) == BackupTestSupport.treeSignature(restored))
    }

    @Test func exportMemoryStaysBoundedOnLargeBodies() throws {
        // Best-effort watermark: exporting a 48 MiB body must not lift the
        // process peak footprint by anywhere near the body size (streamed
        // 4 MiB chunks, never Data(contentsOf:) on whole bodies).
        let source = try BackupTestSupport.temporaryDirectory("mem-src")
        let body = String(repeating: "watermark", count: 48 * 1024 * 1024 / 9)
        _ = try BackupTestSupport.seedEvent(source, content: body, inlineLimit: 1024)
        let backupFile = try BackupTestSupport.temporaryDirectory("mem-out")
            .appendingPathComponent("mem.clipbak")

        var usageBefore = rusage()
        getrusage(RUSAGE_SELF, &usageBefore)
        _ = try BackupTestSupport.export(source, to: backupFile)
        var usageAfter = rusage()
        getrusage(RUSAGE_SELF, &usageAfter)
        let peakDelta = usageAfter.ru_maxrss - usageBefore.ru_maxrss
        #expect(peakDelta < 40 * 1024 * 1024, "export lifted peak RSS by \(peakDelta) bytes")
    }

    // MARK: - Inspect + iteration policy

    @Test func inspectDecryptsManifestOnly() throws {
        let source = try BackupTestSupport.temporaryDirectory("inspect-src")
        let index = try BackupTestSupport.temporaryDirectory("inspect-idx").appendingPathComponent("index.sqlite")
        try BackupTestSupport.seedMixedArchive(source, indexURL: index)
        let backupFile = try BackupTestSupport.temporaryDirectory("inspect-out")
            .appendingPathComponent("inspect.clipbak")
        let exported = try BackupTestSupport.export(source, to: backupFile)

        let inspection = try ClipboardBackupInspector.inspect(
            fileURL: backupFile,
            passphrase: BackupTestSupport.passphrase
        )
        // Dates round-trip at ISO-8601 second precision, so compare the
        // fields rather than whole-struct equality.
        #expect(inspection.manifest.backupID == exported.manifest.backupID)
        #expect(inspection.manifest.counts == exported.manifest.counts)
        #expect(inspection.manifest.entries == exported.manifest.entries)
        #expect(inspection.manifest.totalPlaintextBytes == exported.manifest.totalPlaintextBytes)
        #expect(inspection.manifest.includesSettings == exported.manifest.includesSettings)
        #expect(inspection.iterations == BackupTestSupport.testIterations)
        #expect(inspection.framingIntact)

        #expect(throws: ClipboardBackupError.authenticationFailed) {
            _ = try ClipboardBackupInspector.inspect(
                fileURL: backupFile,
                passphrase: BackupTestSupport.wrongPassphrase
            )
        }
    }

    @Test func defaultIterationsRespectFloor() {
        #expect(ClipboardBackupFormat.calibratedIterations(passphraseLength: 20)
            >= ClipboardBackupFormat.iterationFloor)
    }

    @Test func exportRejectsShortPassphrase() throws {
        let source = try BackupTestSupport.temporaryDirectory("short-src")
        let backupFile = try BackupTestSupport.temporaryDirectory("short-out")
            .appendingPathComponent("short.clipbak")
        #expect(throws: ClipboardBackupError.passphraseTooShort) {
            _ = try ClipboardBackupExporter(archiveRoot: source).export(
                to: backupFile,
                passphrase: Data("seven77".utf8),
                iterationsOverride: BackupTestSupport.testIterations
            )
        }
    }

    // MARK: - Wrong passphrase / tamper / truncation matrix

    private func makeTamperFixture() throws -> (backupFile: URL, restored: URL, indexURL: URL) {
        let source = try BackupTestSupport.temporaryDirectory("tamper-src")
        let index = try BackupTestSupport.temporaryDirectory("tamper-src-idx").appendingPathComponent("index.sqlite")
        try BackupTestSupport.seedMixedArchive(source, indexURL: index)
        let backupFile = try BackupTestSupport.temporaryDirectory("tamper-out")
            .appendingPathComponent("tamper.clipbak")
        _ = try BackupTestSupport.export(source, to: backupFile)
        let restored = try BackupTestSupport.temporaryDirectory("tamper-dst")
        let indexURL = try BackupTestSupport.temporaryDirectory("tamper-dst-idx").appendingPathComponent("index.sqlite")
        return (backupFile, restored, indexURL)
    }

    /// Asserts that restoring `file` fails and writes NOTHING into the
    /// target root (no files, no staging leftovers).
    private func expectZeroWriteFailure(
        _ file: URL,
        restored: URL,
        indexURL: URL,
        passphrase: Data = BackupTestSupport.passphrase,
        check: (ClipboardBackupError) -> Bool
    ) throws {
        let before = try BackupTestSupport.treeSignature(restored)
        let importer = ClipboardBackupImporter(archiveRoot: restored, indexURL: indexURL)
        do {
            _ = try importer.run(
                backupFileURL: file,
                passphrase: passphrase,
                options: ClipboardBackupImportOptions(merge: false),
                dryRun: false
            )
            Issue.record("import unexpectedly succeeded")
        } catch let error as ClipboardBackupError {
            #expect(check(error), "unexpected error: \(error)")
        }
        #expect(try BackupTestSupport.treeSignature(restored) == before)
        #expect(BackupTestSupport.stagingDirectories(restored).isEmpty)
    }

    @Test func wrongPassphraseFailsWithZeroWrites() throws {
        let fixture = try makeTamperFixture()
        try expectZeroWriteFailure(
            fixture.backupFile,
            restored: fixture.restored,
            indexURL: fixture.indexURL,
            passphrase: BackupTestSupport.wrongPassphrase
        ) { $0 == .authenticationFailed }
    }

    @Test func bitFlipInHeaderDetected() throws {
        let fixture = try makeTamperFixture()
        let container = try Data(contentsOf: fixture.backupFile)
        let layout = BackupTestSupport.layout(of: container)
        let flipped = BackupTestSupport.flippingByte(container, at: layout.headerOffset + 2)
        let tamperedFile = fixture.backupFile.deletingLastPathComponent()
            .appendingPathComponent("header-flip.clipbak")
        try flipped.write(to: tamperedFile)
        // A header flip either breaks JSON parsing or changes an
        // authenticated value; both are rejected before any write.
        try expectZeroWriteFailure(tamperedFile, restored: fixture.restored, indexURL: fixture.indexURL) { error in
            error == .authenticationFailed || error == .malformedHeader
        }
    }

    @Test func bitFlipInManifestBoxDetected() throws {
        let fixture = try makeTamperFixture()
        let container = try Data(contentsOf: fixture.backupFile)
        let layout = BackupTestSupport.layout(of: container)
        let flipped = BackupTestSupport.flippingByte(container, at: layout.manifestBoxOffset + layout.manifestBoxLength / 2)
        let tamperedFile = fixture.backupFile.deletingLastPathComponent()
            .appendingPathComponent("manifest-flip.clipbak")
        try flipped.write(to: tamperedFile)
        try expectZeroWriteFailure(tamperedFile, restored: fixture.restored, indexURL: fixture.indexURL) {
            $0 == .authenticationFailed
        }
    }

    @Test func bitFlipInChunkDetected() throws {
        let fixture = try makeTamperFixture()
        let container = try Data(contentsOf: fixture.backupFile)
        let layout = BackupTestSupport.layout(of: container)
        let flipped = BackupTestSupport.flippingByte(container, at: layout.firstChunkOffset + 40)
        let tamperedFile = fixture.backupFile.deletingLastPathComponent()
            .appendingPathComponent("chunk-flip.clipbak")
        try flipped.write(to: tamperedFile)
        try expectZeroWriteFailure(tamperedFile, restored: fixture.restored, indexURL: fixture.indexURL) { error in
            if case .corruptedPayload = error {
                return true
            }
            return false
        }
    }

    @Test func swappedEqualSizeChunksDetectedByPositionalAAD() throws {
        // Two same-size chunks: an 8 MiB body seals to two full 4 MiB
        // boxes, so a swap keeps the framing perfectly valid — only the
        // positional AAD can catch it.
        let source = try BackupTestSupport.temporaryDirectory("swap-src")
        let body = String(repeating: "swapfill", count: 8 * 1024 * 1024 / 8)
        _ = try BackupTestSupport.seedEvent(source, content: body, inlineLimit: 1024)
        let backupFile = try BackupTestSupport.temporaryDirectory("swap-out")
            .appendingPathComponent("swap.clipbak")
        let exported = try BackupTestSupport.export(source, to: backupFile)
        let bodyEntryIndex = try #require(exported.manifest.entries.firstIndex { $0.kind == "body" })

        var container = try Data(contentsOf: backupFile)
        let layout = BackupTestSupport.layout(of: container)
        // Walk framing to the body entry's first chunk.
        var offset = layout.firstChunkOffset
        var boxes: [(offset: Int, length: Int)] = []
        for (index, entry) in exported.manifest.entries.enumerated() {
            for _ in 0..<entry.chunkCount {
                let length = Int(BackupTestSupport.readUInt32LE(container, at: offset))
                boxes.append((offset, length))
                offset += 4 + length
            }
            if index == bodyEntryIndex {
                break
            }
        }
        let first = boxes[boxes.count - 2]
        let second = boxes[boxes.count - 1]
        #expect(first.length == second.length)
        let firstBox = container.subdata(in: (first.offset + 4)..<(first.offset + 4 + first.length))
        let secondBox = container.subdata(in: (second.offset + 4)..<(second.offset + 4 + second.length))
        container.replaceSubrange((first.offset + 4)..<(first.offset + 4 + first.length), with: secondBox)
        container.replaceSubrange((second.offset + 4)..<(second.offset + 4 + second.length), with: firstBox)
        let tamperedFile = backupFile.deletingLastPathComponent().appendingPathComponent("swap-tampered.clipbak")
        try container.write(to: tamperedFile)

        let restored = try BackupTestSupport.temporaryDirectory("swap-dst")
        let indexURL = try BackupTestSupport.temporaryDirectory("swap-idx").appendingPathComponent("index.sqlite")
        try expectZeroWriteFailure(tamperedFile, restored: restored, indexURL: indexURL) { error in
            if case .corruptedPayload = error {
                return true
            }
            return false
        }
    }

    @Test func truncationMatrixRejected() throws {
        let fixture = try makeTamperFixture()
        let container = try Data(contentsOf: fixture.backupFile)
        let layout = BackupTestSupport.layout(of: container)
        let truncationPoints = [
            20,                                        // mid-header
            layout.manifestBoxOffset + 4,              // mid-manifest box
            container.count - 10                       // mid-final-chunk
        ]
        for (index, point) in truncationPoints.enumerated() {
            let truncatedFile = fixture.backupFile.deletingLastPathComponent()
                .appendingPathComponent("trunc-\(index).clipbak")
            try container.prefix(point).write(to: truncatedFile)
            try expectZeroWriteFailure(truncatedFile, restored: fixture.restored, indexURL: fixture.indexURL) {
                $0 == .truncated
            }
        }
    }

    @Test func trailingDataRejected() throws {
        let fixture = try makeTamperFixture()
        var container = try Data(contentsOf: fixture.backupFile)
        container.append(0x00)
        let trailingFile = fixture.backupFile.deletingLastPathComponent()
            .appendingPathComponent("trailing.clipbak")
        try container.write(to: trailingFile)
        try expectZeroWriteFailure(trailingFile, restored: fixture.restored, indexURL: fixture.indexURL) {
            $0 == .trailingData
        }
    }

    @Test func iterationBoundsEnforcedOnImport() throws {
        let fixture = try makeTamperFixture()
        let container = try Data(contentsOf: fixture.backupFile)
        for hostile in [50_000, 20_000_000] {
            let rebuilt = try BackupTestSupport.replacingHeader(container) { json in
                json["iterations"] = hostile
            }
            let boundsFile = fixture.backupFile.deletingLastPathComponent()
                .appendingPathComponent("bounds-\(hostile).clipbak")
            try rebuilt.write(to: boundsFile)
            try expectZeroWriteFailure(boundsFile, restored: fixture.restored, indexURL: fixture.indexURL) {
                $0 == .iterationsOutOfBounds(hostile)
            }
        }
    }

    @Test func futureFormatVersionRejected() throws {
        let fixture = try makeTamperFixture()
        var container = try Data(contentsOf: fixture.backupFile)
        container.replaceSubrange(8..<12, with: ClipboardBackupExporter.uint32LE(2))
        let futureFile = fixture.backupFile.deletingLastPathComponent()
            .appendingPathComponent("future.clipbak")
        try container.write(to: futureFile)
        try expectZeroWriteFailure(futureFile, restored: fixture.restored, indexURL: fixture.indexURL) {
            $0 == .unsupportedFormatVersion(2)
        }
    }

    @Test func notABackupFileRejected() throws {
        let fixture = try makeTamperFixture()
        let bogusFile = fixture.backupFile.deletingLastPathComponent()
            .appendingPathComponent("bogus.clipbak")
        try Data("NOTCLIPB not a backup".utf8).write(to: bogusFile)
        try expectZeroWriteFailure(bogusFile, restored: fixture.restored, indexURL: fixture.indexURL) {
            $0 == .notABackupFile
        }
    }

    // MARK: - Hostile entry paths

    /// Builds a syntactically perfect container whose manifest carries a
    /// hostile entry path, using the real keys/sealing primitives.
    private func craftContainer(entryPath: String, to fileURL: URL) throws {
        let backupID = UUID()
        let salt = Data((0..<16).map { UInt8($0) })
        let iterations = BackupTestSupport.testIterations
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]

        let header = ClipboardBackupKDFHeader(
            backupID: backupID.uuidString,
            createdAt: Date(),
            kdf: "pbkdf2-hmac-sha256",
            iterations: iterations,
            salt: salt.base64EncodedString(),
            cipher: "aes-256-gcm",
            subkeyDerivation: "hkdf-sha256"
        )
        let payload = Data("hostile payload".utf8)
        let payloadHash = "sha256:" + SHA256.hash(data: payload).map { String(format: "%02x", $0) }.joined()
        let manifest = ClipboardBackupManifest(
            manifestVersion: 1,
            backupID: backupID.uuidString,
            createdAt: Date(),
            appVersion: "test",
            eventSchemaVersion: 1,
            archiveFormatVersion: 1,
            includesSettings: false,
            counts: ClipboardBackupManifest.Counts(),
            earliestCapturedAt: nil,
            latestCapturedAt: nil,
            chunkSize: ClipboardBackupFormat.chunkSize,
            totalPlaintextBytes: Int64(payload.count),
            entries: [
                .init(path: entryPath, kind: "body", bytes: Int64(payload.count), sha256: payloadHash, chunkCount: 1)
            ],
            filesNotIncluded: []
        )
        let keys = try ClipboardBackupKeys(
            passphrase: BackupTestSupport.passphrase,
            salt: salt,
            iterations: iterations
        )
        let headerData = try encoder.encode(header)
        let manifestBox = try AES.GCM.seal(
            try encoder.encode(manifest),
            using: keys.manifestKey,
            authenticating: headerData
        ).combined!
        let chunkBox = try AES.GCM.seal(
            payload,
            using: keys.payloadKey,
            authenticating: ClipboardBackupFormat.chunkAAD(backupID: backupID, entryIndex: 0, chunkIndex: 0)
        ).combined!

        var container = Data()
        container.append(ClipboardBackupFormat.magic)
        container.append(ClipboardBackupExporter.uint32LE(1))
        container.append(ClipboardBackupExporter.uint32LE(UInt32(headerData.count)))
        container.append(headerData)
        container.append(ClipboardBackupExporter.uint64LE(UInt64(manifestBox.count)))
        container.append(manifestBox)
        container.append(ClipboardBackupExporter.uint32LE(UInt32(chunkBox.count)))
        container.append(chunkBox)
        try container.write(to: fileURL)
    }

    @Test func hostileEntryPathsRejectedBeforeAnyWrite() throws {
        let hostilePaths = [
            "../escape.txt",
            "/absolute/path.txt",
            "raw/../../escape.txt",
            "evil/outside-allowlist.txt",
            "raw/.hidden-component/x.txt",
            "journal.json",
            "pre-images/raw/x.ndjson"
        ]
        let outDirectory = try BackupTestSupport.temporaryDirectory("hostile-out")
        for (index, path) in hostilePaths.enumerated() {
            let file = outDirectory.appendingPathComponent("hostile-\(index).clipbak")
            try craftContainer(entryPath: path, to: file)
            let restored = try BackupTestSupport.temporaryDirectory("hostile-dst-\(index)")
            let indexURL = outDirectory.appendingPathComponent("hostile-\(index).sqlite")
            try expectZeroWriteFailure(file, restored: restored, indexURL: indexURL) { error in
                if case .entryPathRejected = error {
                    return true
                }
                return false
            }
        }
    }

    // MARK: - Settings include/apply matrix

    @Test func settingsIncludeAndApplyMatrix() throws {
        let source = try BackupTestSupport.temporaryDirectory("settings-src")
        _ = try BackupTestSupport.seedEvent(source, content: "settings fixture event")
        let settingsDirectory = try BackupTestSupport.temporaryDirectory("settings-file")
        let sourceSettingsURL = settingsDirectory.appendingPathComponent("settings.json")
        var settings = ClipboardSettings()
        settings.recentItemLimit = 77
        settings.excludedAppNameFragments = ["synthetic-fragment"]
        try ClipboardSettingsStore(settingsURL: sourceSettingsURL).save(settings)

        let outDirectory = try BackupTestSupport.temporaryDirectory("settings-out")
        let withoutSettings = outDirectory.appendingPathComponent("no-settings.clipbak")
        let withSettings = outDirectory.appendingPathComponent("with-settings.clipbak")
        let plainResult = try BackupTestSupport.export(source, to: withoutSettings)
        #expect(plainResult.manifest.includesSettings == false)
        let settingsResult = try BackupTestSupport.export(
            source,
            to: withSettings,
            includeSettings: true,
            settingsURL: sourceSettingsURL
        )
        #expect(settingsResult.manifest.includesSettings == true)

        // --apply-settings against a backup with none: hard error.
        let restoredA = try BackupTestSupport.temporaryDirectory("settings-dst-a")
        let importerA = ClipboardBackupImporter(
            archiveRoot: restoredA,
            indexURL: outDirectory.appendingPathComponent("a.sqlite"),
            settingsURL: restoredA.deletingLastPathComponent().appendingPathComponent("a-settings.json")
        )
        #expect(throws: ClipboardBackupError.backupHasNoSettings) {
            _ = try importerA.run(
                backupFileURL: withoutSettings,
                passphrase: BackupTestSupport.passphrase,
                options: ClipboardBackupImportOptions(merge: false, applySettings: true),
                dryRun: false
            )
        }

        // Settings in the backup but NOT applied by default.
        let restoredB = try BackupTestSupport.temporaryDirectory("settings-dst-b")
        let targetSettingsB = try BackupTestSupport.temporaryDirectory("settings-dst-b-cfg")
            .appendingPathComponent("settings.json")
        let importerB = ClipboardBackupImporter(
            archiveRoot: restoredB,
            indexURL: outDirectory.appendingPathComponent("b.sqlite"),
            settingsURL: targetSettingsB
        )
        let outcomeB = try importerB.run(
            backupFileURL: withSettings,
            passphrase: BackupTestSupport.passphrase,
            options: ClipboardBackupImportOptions(merge: false),
            dryRun: false
        )
        #expect(outcomeB.appliedSettings == false)
        #expect(!FileManager.default.fileExists(atPath: targetSettingsB.path))
        // meta/settings.json must never land inside the archive root.
        #expect(!FileManager.default.fileExists(atPath: restoredB.appendingPathComponent("meta").path))

        // Applied on request, through the tolerant decoder + store.
        let restoredC = try BackupTestSupport.temporaryDirectory("settings-dst-c")
        let targetSettingsC = try BackupTestSupport.temporaryDirectory("settings-dst-c-cfg")
            .appendingPathComponent("settings.json")
        let importerC = ClipboardBackupImporter(
            archiveRoot: restoredC,
            indexURL: outDirectory.appendingPathComponent("c.sqlite"),
            settingsURL: targetSettingsC
        )
        let outcomeC = try importerC.run(
            backupFileURL: withSettings,
            passphrase: BackupTestSupport.passphrase,
            options: ClipboardBackupImportOptions(merge: false, applySettings: true),
            dryRun: false
        )
        #expect(outcomeC.appliedSettings == true)
        let loaded = ClipboardSettingsStore(settingsURL: targetSettingsC).load()
        #expect(loaded.recentItemLimit == 77)
        #expect(loaded.excludedAppNameFragments == ["synthetic-fragment"])
    }

    // MARK: - Layout drift honesty

    @Test func nonAllowlistedFilesReportedByName() throws {
        let source = try BackupTestSupport.temporaryDirectory("drift-src")
        _ = try BackupTestSupport.seedEvent(source, content: "drift fixture")
        try Data("unknown".utf8).write(to: source.appendingPathComponent("rogue-file.bin"))
        try FileManager.default.createDirectory(
            at: source.appendingPathComponent("rogue-dir"),
            withIntermediateDirectories: true
        )
        try Data("x".utf8).write(to: source.appendingPathComponent("rogue-dir/inner.txt"))

        let backupFile = try BackupTestSupport.temporaryDirectory("drift-out")
            .appendingPathComponent("drift.clipbak")
        let result = try BackupTestSupport.export(source, to: backupFile)
        #expect(result.manifest.filesNotIncluded.contains("rogue-file.bin"))
        #expect(result.manifest.filesNotIncluded.contains("rogue-dir/"))
        #expect(!result.manifest.entries.contains { $0.path.contains("rogue") })
    }
}
