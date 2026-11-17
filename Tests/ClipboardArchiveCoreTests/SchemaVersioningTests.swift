import Foundation
import Testing
@testable import ClipboardArchiveCore

@Suite("Schema Versioning")
struct SchemaVersioningTests {
    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("clipboard-schema-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func archiveDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    private func archiveEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }

    @Test
    func testLegacyLineDecodesAsVersionOneWithAllFieldsIntact() throws {
        let event = try archiveDecoder().decode(
            StoredClipboardEvent.self,
            from: Data(SyntheticFixtures.legacyV1Line().utf8)
        )

        #expect(event.schemaVersion == 1)
        #expect(event.id == "clip_20270115T080000Z_legacyfixtur_ab12cd34")
        #expect(event.capturedAt == ISO8601DateFormatter().date(from: "2027-01-15T08:00:00Z"))
        #expect(event.contentType == .text)
        #expect(event.contentHash == "sha256:legacyfixture")
        #expect(event.contentPreview == "synthetic legacy fixture note")
        #expect(event.contentInline == "synthetic legacy fixture note")
        #expect(event.rawContentPath == nil)
        #expect(event.sourceApp == ClipboardSourceApp(name: "Notes", bundleIdentifier: "com.apple.Notes"))
        #expect(event.pasteboardTypes == ["public.utf8-plain-text"])
        #expect(event.byteCount == 29)
        #expect(event.characterCount == 29)
        #expect(event.lineCount == 1)
        #expect(event.privacyLabel == .privateLocal)
        #expect(event.allowedUse == [.localSearch, .localAnalysis])
        #expect(event.sensitivityFlags.isEmpty)
        #expect(event.uiVisibleUntil == ISO8601DateFormatter().date(from: "2027-01-22T08:00:00Z"))
    }

    @Test
    func testCurrentEventRoundTripsForEveryContentType() throws {
        for original in SyntheticFixtures.currentEventsPerContentType() {
            let encoded = try archiveEncoder().encode(original)
            let decoded = try archiveDecoder().decode(StoredClipboardEvent.self, from: encoded)

            #expect(original.schemaVersion == StoredClipboardEvent.currentSchemaVersion)
            #expect(decoded == original)

            let json = String(data: encoded, encoding: .utf8) ?? ""
            #expect(json.contains("\"schemaVersion\":\(StoredClipboardEvent.currentSchemaVersion)"))
        }
    }

    @Test
    func testFutureLineDecodesTolerantlyAndPreservesUnknownContentType() throws {
        let event = try archiveDecoder().decode(
            StoredClipboardEvent.self,
            from: Data(SyntheticFixtures.futureVersionLine().utf8)
        )

        #expect(event.schemaVersion == 3)
        #expect(event.contentType == .other("hologram"))
        #expect(event.contentType.rawValue == "hologram")

        let reencoded = String(data: try archiveEncoder().encode(event), encoding: .utf8) ?? ""
        #expect(reencoded.contains("\"contentType\":\"hologram\""))
        #expect(reencoded.contains("\"schemaVersion\":3"))
    }

    @Test
    func testCorruptLineFailsDecodeAndIsSkippedByReaderStyleLoop() throws {
        let decoder = archiveDecoder()

        #expect(throws: (any Error).self) {
            try decoder.decode(
                StoredClipboardEvent.self,
                from: Data(SyntheticFixtures.corruptLine().utf8)
            )
        }

        // Mirror of ClipboardArchiveReader's per-line decode-failure skip.
        let lines = [
            SyntheticFixtures.legacyV1Line(),
            SyntheticFixtures.corruptLine(),
            SyntheticFixtures.blockedEventLine(),
            SyntheticFixtures.futureVersionLine(),
            SyntheticFixtures.benchmarkGeneratorLine(),
        ]
        let decoded = lines.compactMap { line in
            try? decoder.decode(StoredClipboardEvent.self, from: Data(line.utf8))
        }

        #expect(decoded.count == 3)
        #expect(!decoded.contains { $0.id == "clip_synthetic_corrupt" })
    }

    @Test
    func testBenchmarkGeneratorShapedLineDecodes() throws {
        let event = try archiveDecoder().decode(
            StoredClipboardEvent.self,
            from: Data(SyntheticFixtures.benchmarkGeneratorLine(index: 42).utf8)
        )

        #expect(event.schemaVersion == 1)
        #expect(event.id == "clip_synthetic_42")
        #expect(event.contentType == .text)
        #expect(event.rawContentPath == nil)
        #expect(event.contentInline?.contains("benchmark-search-token-42") == true)
        #expect(event.sourceApp == ClipboardSourceApp(name: "Synthetic", bundleIdentifier: "local.synthetic"))
    }

    @Test
    func testArchiveFormatMarkerIsCreatedSecurelyOnceAndNeverRewritten() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let writer = ClipboardArchiveWriter(archiveRoot: root)
        let markerURL = root.appendingPathComponent("archive-format.json")

        #expect(!FileManager.default.fileExists(atPath: markerURL.path))

        _ = try writer.archiveAllowedCapture(ClipboardCapture(
            capturedAt: Date(timeIntervalSince1970: 1_800_000_000),
            content: "synthetic marker fixture",
            sourceApp: ClipboardSourceApp(name: "Synthetic Test")
        ))

        #expect(FileManager.default.fileExists(atPath: markerURL.path))
        let object = try JSONSerialization.jsonObject(with: Data(contentsOf: markerURL)) as? [String: Int]
        #expect(object == ["archiveFormatVersion": 1, "minReader": 1])
        let attributes = try FileManager.default.attributesOfItem(atPath: markerURL.path)
        #expect((attributes[.posixPermissions] as? NSNumber)?.int16Value == 0o600)

        // Overwrite with a sentinel: later writes must leave the marker alone.
        let sentinel = Data("{\"archiveFormatVersion\":1,\"minReader\":1,\"sentinel\":1}\n".utf8)
        try sentinel.write(to: markerURL)
        _ = try writer.archiveAllowedCapture(ClipboardCapture(
            capturedAt: Date(timeIntervalSince1970: 1_800_000_100),
            content: "synthetic marker fixture second write",
            sourceApp: ClipboardSourceApp(name: "Synthetic Test")
        ))

        #expect(try Data(contentsOf: markerURL) == sentinel)
    }

    @Test
    func testArchiveFormatMarkerIsAlsoWrittenByBlockedCapturePath() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let writer = ClipboardArchiveWriter(archiveRoot: root)

        try writer.archiveBlockedCapture(
            ClipboardCapture(
                capturedAt: Date(timeIntervalSince1970: 1_800_000_000),
                content: "synthetic blocked fixture",
                sourceApp: ClipboardSourceApp(name: "Dashlane")
            ),
            reason: "source_app_denylist:dashlane"
        )

        let markerURL = root.appendingPathComponent("archive-format.json")
        #expect(FileManager.default.fileExists(atPath: markerURL.path))
    }
}
