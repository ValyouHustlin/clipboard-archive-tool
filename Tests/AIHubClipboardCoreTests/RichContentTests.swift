import CryptoKit
import Foundation
import Testing
@testable import ClipboardArchiveCore

/// Slice 6 rich-format coverage. Every byte here is authored synthetic
/// fixture data; nothing is sampled from a live archive (contract 10), and
/// every archive lives in an isolated temporary root.
@Suite("Rich Content")
struct RichContentTests {
    // MARK: - Fixtures

    /// 1×1 red PNG (~70 bytes) — authored synthetic bytes.
    private static func tinyPNGData() -> Data {
        Data(base64Encoded:
            "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg=="
        ) ?? Data()
    }

    private static func tinyRTFData() -> Data {
        Data("{\\rtf1\\ansi {\\b Synthetic bold} rich fixture}".utf8)
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("clipboard-rich-tests-\(UUID().uuidString)", isDirectory: true)
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

    private let fixtureDate = Date(timeIntervalSince1970: 1_800_000_000) // 2027-01-15T08:00:00Z

    private func sourceApp(_ name: String = "Synthetic Fixture") -> ClipboardSourceApp {
        ClipboardSourceApp(name: name, bundleIdentifier: "local.synthetic.fixture")
    }

    private func imageCapture(data: Data? = nil, at date: Date? = nil) -> ClipboardCapture {
        let bytes = data ?? Self.tinyPNGData()
        return ClipboardCapture(
            capturedAt: date ?? fixtureDate,
            content: "",
            sourceApp: sourceApp("Preview"),
            pasteboardTypes: ["public.png"],
            rich: .image(data: bytes, uti: "public.png", pixelWidth: 1, pixelHeight: 1)
        )
    }

    private func rtfCapture(fallback: String = "Synthetic bold rich fixture") -> ClipboardCapture {
        ClipboardCapture(
            capturedAt: fixtureDate.addingTimeInterval(10),
            content: fallback,
            sourceApp: sourceApp("TextEdit"),
            pasteboardTypes: ["public.rtf", "public.utf8-plain-text"],
            rich: .rtf(data: Self.tinyRTFData())
        )
    }

    private func fileListCapture(files: [ClipboardRichFileReference]) -> ClipboardCapture {
        ClipboardCapture(
            capturedAt: fixtureDate.addingTimeInterval(20),
            content: files.map(\.path).joined(separator: "\n"),
            sourceApp: sourceApp("Finder"),
            pasteboardTypes: ["public.file-url"],
            rich: .fileList(files)
        )
    }

    private func colorCapture() -> ClipboardCapture {
        ClipboardCapture(
            capturedAt: fixtureDate.addingTimeInterval(30),
            content: "#3A7BFF",
            sourceApp: sourceApp("Xcode"),
            pasteboardTypes: ["com.apple.cocoa.pasteboard.color"],
            rich: .color(hex: "#3A7BFF", colorSpace: "sRGB")
        )
    }

    private func linkCapture(
        url: String = "https://example.com/launch-notes",
        title: String = "Launch Notes Fixture"
    ) -> ClipboardCapture {
        ClipboardCapture(
            capturedAt: fixtureDate.addingTimeInterval(40),
            content: url + "\n" + title,
            sourceApp: sourceApp("Safari"),
            pasteboardTypes: ["public.url", "public.url-name"],
            rich: .link(url: url, title: title)
        )
    }

    private func richBodyFiles(under root: URL) -> [URL] {
        (FileManager.default.enumerator(
            at: root.appendingPathComponent("raw"),
            includingPropertiesForKeys: nil
        )?.compactMap { $0 as? URL } ?? [])
            .filter { ["png", "tiff", "rtf", "json"].contains($0.pathExtension) }
    }

    // MARK: - Per-kind round-trips (byte equality)

    @Test
    func testImageCaptureRoundTripsBytesExactly() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let original = Self.tinyPNGData()
        #expect(!original.isEmpty)

        let event = try ClipboardArchiveWriter(archiveRoot: root)
            .archiveAllowedCapture(imageCapture(data: original))

        #expect(event.contentType == .image)
        #expect(event.schemaVersion == 2)
        #expect(event.contentInline == nil)
        // rawContentPath stays plain-text-only forever: never set for images.
        #expect(event.rawContentPath == nil)
        let rich = try #require(event.richContent)
        #expect(rich.kind == "image")
        #expect(rich.bodyType == "public.png")
        #expect(rich.imagePixelWidth == 1)
        #expect(rich.imagePixelHeight == 1)
        #expect(rich.bodyByteCount == original.count)
        #expect(rich.hasPlainTextFallback == false)
        #expect(event.contentPreview.hasPrefix("Image 1×1"))
        #expect(event.byteCount == original.count)
        let expectedHash = "sha256:" + SHA256.hash(data: original)
            .map { String(format: "%02x", $0) }.joined()
        #expect(event.contentHash == expectedHash)

        let restored = try ClipboardArchiveReader(archiveRoot: root).richBody(for: event)
        #expect(restored == original)
    }

    @Test
    func testRTFCaptureRoundTripsBytesAndKeepsPlainFallback() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let original = Self.tinyRTFData()

        let event = try ClipboardArchiveWriter(archiveRoot: root)
            .archiveAllowedCapture(rtfCapture())

        #expect(event.contentType == .richText)
        #expect(event.schemaVersion == 2)
        // The plain fallback follows the EXISTING inline rules.
        #expect(event.contentInline == "Synthetic bold rich fixture")
        #expect(event.contentPreview == "Synthetic bold rich fixture")
        let rich = try #require(event.richContent)
        #expect(rich.kind == "rtf")
        #expect(rich.bodyPath?.hasSuffix(".rtf") == true)
        #expect(rich.hasPlainTextFallback)

        let reader = ClipboardArchiveReader(archiveRoot: root)
        #expect(try reader.richBody(for: event) == original)
        // content(for:) stays the plain fallback (old-build safe).
        #expect(try reader.content(for: event) == "Synthetic bold rich fixture")
    }

    @Test
    func testFileListStoresMetadataOnlyAndNeverFileContents() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        // A real on-disk file whose CONTENTS must never enter the archive.
        let sourceDirectory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: sourceDirectory) }
        let secretBody = "synthetic-file-contents-that-must-never-be-archived"
        let fileURL = sourceDirectory.appendingPathComponent("invoicefixture.pdf")
        try Data(secretBody.utf8).write(to: fileURL)

        let files = [
            ClipboardRichFileReference(
                name: "invoicefixture.pdf",
                path: fileURL.path,
                byteCount: secretBody.utf8.count,
                uti: "com.adobe.pdf"
            ),
            ClipboardRichFileReference(name: "notesfixture.txt", path: "/tmp/notesfixture.txt")
        ]
        let event = try ClipboardArchiveWriter(archiveRoot: root)
            .archiveAllowedCapture(fileListCapture(files: files))

        #expect(event.contentType == .fileReference)
        let rich = try #require(event.richContent)
        #expect(rich.kind == "file-list")
        #expect(rich.files?.count == 2)
        #expect(rich.fileCount == 2)
        #expect(rich.filesTruncated == nil)
        #expect(rich.bodyPath == nil)
        #expect(event.contentPreview == "2 files: invoicefixture.pdf, notesfixture.txt")
        #expect(event.contentInline == files.map(\.path).joined(separator: "\n"))

        // File CONTENTS never enter the archive (contract 7).
        let archived = (FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)?
            .compactMap { $0 as? URL } ?? [])
            .filter { (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true }
        for url in archived {
            let text = (try? String(contentsOf: url)) ?? ""
            #expect(!text.contains(secretBody), "file contents leaked into \(url.lastPathComponent)")
        }
    }

    @Test
    func testFileListBeyond100SpillsFullListIntoJSONBody() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let files = (0..<150).map { slot in
            ClipboardRichFileReference(
                name: "fixture-\(slot).txt",
                path: "/tmp/synthetic-spill/fixture-\(slot).txt"
            )
        }
        let event = try ClipboardArchiveWriter(archiveRoot: root)
            .archiveAllowedCapture(fileListCapture(files: files))

        let rich = try #require(event.richContent)
        #expect(rich.files?.count == 100)
        #expect(rich.fileCount == 150)
        #expect(rich.filesTruncated == true)
        #expect(rich.bodyPath?.hasSuffix(".json") == true)

        let reader = ClipboardArchiveReader(archiveRoot: root)
        let fullList = reader.fileList(for: event)
        #expect(fullList.count == 150)
        #expect(fullList.last?.name == "fixture-149.txt")
    }

    @Test
    func testColorAndLinkStayInlineOnly() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let writer = ClipboardArchiveWriter(archiveRoot: root)

        let color = try writer.archiveAllowedCapture(colorCapture())
        #expect(color.contentType == .color)
        #expect(color.richContent?.kind == "color")
        #expect(color.richContent?.colorHex == "#3A7BFF")
        #expect(color.richContent?.colorSpace == "sRGB")
        #expect(color.richContent?.bodyPath == nil)
        #expect(color.contentPreview == "Color #3A7BFF")
        #expect(color.contentInline == "#3A7BFF")

        let link = try writer.archiveAllowedCapture(linkCapture())
        // Formatted links stay "url" — old builds keep their Links filter.
        #expect(link.contentType == .url)
        #expect(link.richContent?.kind == "link")
        #expect(link.richContent?.linkURL == "https://example.com/launch-notes")
        #expect(link.richContent?.linkTitle == "Launch Notes Fixture")
        #expect(link.richContent?.bodyPath == nil)
        #expect(link.contentPreview == "Launch Notes Fixture — https://example.com/launch-notes")

        // No body files at all for inline-only kinds.
        #expect(richBodyFiles(under: root).isEmpty)
    }

    // MARK: - Text byte-identity pin (contract 1 amendment)

    @Test
    func testTextEventLineStaysByteIdenticalToV1Shape() throws {
        // Pinned v1-shape line: EXACTLY what pre-Slice-6 builds wrote for a
        // text event (schemaVersion stamped 1, no richContent key).
        let pinned = #"{"allowedUse":["local-search","local-analysis"],"byteCount":29,"capturedAt":"2027-01-15T08:00:00Z","characterCount":29,"contentHash":"sha256:legacyfixture","contentInline":"synthetic legacy fixture note","contentPreview":"synthetic legacy fixture note","contentType":"text","id":"clip_20270115T080000Z_legacyfixtur_ab12cd34","lineCount":1,"pasteboardTypes":["public.utf8-plain-text"],"privacyLabel":"private-local","schemaVersion":1,"sensitivityFlags":[],"sourceApp":{"bundleIdentifier":"com.apple.Notes","name":"Notes"},"uiVisibleUntil":"2027-01-22T08:00:00Z"}"#

        let capturedAt = try #require(ISO8601DateFormatter().date(from: "2027-01-15T08:00:00Z"))
        let event = StoredClipboardEvent(
            id: "clip_20270115T080000Z_legacyfixtur_ab12cd34",
            capturedAt: capturedAt,
            contentType: .text,
            contentHash: "sha256:legacyfixture",
            contentPreview: "synthetic legacy fixture note",
            contentInline: "synthetic legacy fixture note",
            rawContentPath: nil,
            sourceApp: ClipboardSourceApp(name: "Notes", bundleIdentifier: "com.apple.Notes"),
            pasteboardTypes: ["public.utf8-plain-text"],
            byteCount: 29,
            characterCount: 29,
            lineCount: 1,
            privacyLabel: .privateLocal,
            allowedUse: [.localSearch, .localAnalysis],
            sensitivityFlags: [],
            uiVisibleUntil: capturedAt.addingTimeInterval(7 * 86_400),
            schemaVersion: 1,
            richContent: nil
        )
        let encoded = String(data: try archiveEncoder().encode(event), encoding: .utf8)
        #expect(encoded == pinned)
    }

    @Test
    func testWriterStampsTextLinesVersionOneWithoutRichContentKey() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let event = try ClipboardArchiveWriter(archiveRoot: root).archiveAllowedCapture(
            ClipboardCapture(
                capturedAt: fixtureDate,
                content: "plain text fixture line",
                sourceApp: sourceApp("Notes"),
                pasteboardTypes: ["public.utf8-plain-text"]
            )
        )
        #expect(event.schemaVersion == 1)
        #expect(event.richContent == nil)

        let dayFile = root.appendingPathComponent("raw/2027/01/2027-01-15_clipboard-events.ndjson")
        let line = try String(contentsOf: dayFile)
        #expect(line.contains("\"schemaVersion\":1"))
        #expect(!line.contains("richContent"))
    }

    // MARK: - Image size cap

    @Test
    func testOversizedImageIsBlockedWithNoBodyFileAndNoStoredLine() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let cap = 10 * 1024 * 1024
        let oversized = Data(count: 11 * 1024 * 1024)
        let ingestor = ClipboardIngestor(
            archiveWriter: ClipboardArchiveWriter(archiveRoot: root),
            richImageMaxBytes: cap
        )

        let result = try ingestor.ingest(imageCapture(data: oversized))

        #expect(result == .blocked(
            reason: "image_exceeds_size_cap:\(oversized.count)b:limit:\(cap)b"
        ))
        // No stored event, no body file of any kind — only the blocked
        // audit line exists.
        let reader = ClipboardArchiveReader(archiveRoot: root)
        #expect(try reader.recentItems(since: .distantPast, limit: 10).isEmpty)
        #expect(richBodyFiles(under: root).isEmpty)
        let blocked = try reader.recentBlockedEvents(since: .distantPast, limit: 10)
        #expect(blocked.count == 1)
        #expect(blocked.first?.reason.hasPrefix("image_exceeds_size_cap:") == true)
    }

    @Test
    func testImageWithinCapIsStoredUnderTheSameIngestor() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let ingestor = ClipboardIngestor(archiveWriter: ClipboardArchiveWriter(archiveRoot: root))
        let result = try ingestor.ingest(imageCapture())
        guard case let .stored(event, _) = result else {
            Issue.record("in-cap image was not stored")
            return
        }
        #expect(event.contentType == .image)
    }

    // MARK: - Containment

    @Test
    func testRichBodyContainmentEscapeThrowsAndRedactorReportsUnsafePath() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        // Hand-built hostile line: bodyPath tries to escape the root.
        let capturedAt = try #require(ISO8601DateFormatter().date(from: "2027-01-15T08:00:00Z"))
        let hostile = StoredClipboardEvent(
            id: "clip_20270115T080000Z_hostilefixtu_aa11bb22",
            capturedAt: capturedAt,
            contentType: .image,
            contentHash: "sha256:hostilefixture",
            contentPreview: "Image (68 bytes)",
            contentInline: nil,
            rawContentPath: nil,
            sourceApp: sourceApp(),
            pasteboardTypes: ["public.png"],
            byteCount: 68,
            characterCount: 0,
            lineCount: 1,
            privacyLabel: .privateLocal,
            allowedUse: [.localSearch, .localAnalysis],
            sensitivityFlags: [],
            uiVisibleUntil: capturedAt.addingTimeInterval(7 * 86_400),
            schemaVersion: 2,
            richContent: ClipboardRichContent(
                kind: "image",
                bodyPath: "../../escape.png",
                bodyType: "public.png",
                hasPlainTextFallback: false
            )
        )
        var line = try archiveEncoder().encode(hostile)
        line.append(0x0A)
        let dayFile = root.appendingPathComponent("raw/2027/01/2027-01-15_clipboard-events.ndjson")
        try FileManager.default.createDirectory(
            at: dayFile.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try line.write(to: dayFile)

        let reader = ClipboardArchiveReader(archiveRoot: root)
        let event = try #require(try reader.event(withID: hostile.id))
        #expect(throws: ClipboardArchivePathError.self) {
            _ = try reader.richBody(for: event)
        }

        let result = try ClipboardArchiveRedactor(
            archiveRoot: root,
            indexURL: root.appendingPathComponent("index.sqlite")
        ).redact(eventID: hostile.id)
        #expect(result.skippedUnsafeBodyPath)
        // The escape target must not have been touched or created.
        #expect(!FileManager.default.fileExists(
            atPath: root.deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent("escape.png").path
        ))
    }

    // MARK: - Privacy fixtures (contract 10)

    @Test
    func testConcealedTypeBlocksRichImageIdentically() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        var capture = imageCapture()
        capture.pasteboardTypes = ["org.nspasteboard.concealedtype", "public.png"]
        let result = try ClipboardIngestor(
            archiveWriter: ClipboardArchiveWriter(archiveRoot: root)
        ).ingest(capture)
        guard case let .blocked(reason) = result else {
            Issue.record("concealed rich capture was stored")
            return
        }
        #expect(reason.hasPrefix("pasteboard_type_denylist:"))
        #expect(richBodyFiles(under: root).isEmpty)
    }

    @Test
    func testSecretBearingRTFFallbackAndLinkAreBlockedWithNoBodies() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let ingestor = ClipboardIngestor(archiveWriter: ClipboardArchiveWriter(archiveRoot: root))

        // Secret in the RTF plain fallback (the detector substrate).
        var rtf = rtfCapture(fallback: "OPENAI_API_KEY=" + "sk-" + "abcdefghijklmnopqrstuvwxyz123456")
        rtf.rich = .rtf(data: Self.tinyRTFData())
        guard case let .blocked(rtfReason) = try ingestor.ingest(rtf) else {
            Issue.record("secret-bearing rtf fallback was stored")
            return
        }
        #expect(rtfReason.hasPrefix("secret_detector:"))

        // Secret-shaped token inside a titled link (url+title substrate).
        let token = "ghp_" + "abcdefghijklmnopqrstuvwxyz123456789"
        let link = linkCapture(url: "https://example.com/?t=\(token)", title: "Token Page")
        guard case let .blocked(linkReason) = try ingestor.ingest(link) else {
            Issue.record("secret-bearing link was stored")
            return
        }
        #expect(linkReason.hasPrefix("secret_detector:"))

        // Nothing stored, no rich bodies on disk.
        #expect(try ClipboardArchiveReader(archiveRoot: root)
            .recentItems(since: .distantPast, limit: 10).isEmpty)
        #expect(richBodyFiles(under: root).isEmpty)
    }

    @Test
    func testBenignRichCapturesAreAllowedFalsePositiveGuard() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let ingestor = ClipboardIngestor(archiveWriter: ClipboardArchiveWriter(archiveRoot: root))
        // Ordinary prose fallback — must NOT trip the secret detector.
        let result = try ingestor.ingest(rtfCapture(
            fallback: "Meeting notes: review the launch checklist before Friday."
        ))
        guard case let .stored(event, _) = result else {
            Issue.record("benign rtf capture was blocked")
            return
        }
        #expect(event.contentType == .richText)
        #expect(event.privacyLabel == .privateLocal)
    }

    @Test
    func testSingleFilePathDoesNotTripEntropyHeuristicButTokenNamedFileStillBlocks() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let ingestor = ClipboardIngestor(archiveWriter: ClipboardArchiveWriter(archiveRoot: root))

        // False-positive guard: a single file path is structurally one
        // high-entropy token; it must NOT be blocked by the bare-token
        // heuristic.
        let single = [ClipboardRichFileReference(
            name: "invoicefixture.pdf",
            path: "/tmp/secretdirtoken123/invoicefixture.pdf"
        )]
        guard case .stored = try ingestor.ingest(fileListCapture(files: single)) else {
            Issue.record("single-file copy was false-positive blocked")
            return
        }

        // Pattern-based detection still applies to file names/paths.
        let tokenNamed = [ClipboardRichFileReference(
            name: "ghp_" + "abcdefghijklmnopqrstuvwxyz123456789.txt",
            path: "/tmp/ghp_" + "abcdefghijklmnopqrstuvwxyz123456789.txt"
        )]
        guard case let .blocked(reason) = try ingestor.ingest(fileListCapture(files: tokenNamed)) else {
            Issue.record("token-named file copy was stored")
            return
        }
        #expect(reason.hasPrefix("secret_detector:"))
    }

    @Test
    func testStoreNoIndexRuleAppliesToRichCapturesIdentically() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let indexURL = try temporaryDirectory().appendingPathComponent("index.sqlite")
        let index = ClipboardDerivedIndex(archiveRoot: root, indexURL: indexURL)
        let settings = ClipboardSettings(
            appPrivacyRules: [
                "com.example.crm": ClipboardAppPrivacyRule(
                    mode: ClipboardAppPrivacyRule.storeNoIndexMode
                )
            ]
        )
        let ingestor = ClipboardIngestor(
            filter: ClipboardPrivacyFilter(settings: settings),
            archiveWriter: ClipboardArchiveWriter(archiveRoot: root),
            derivedIndex: index
        )

        // Baseline allowed event so the index database exists.
        _ = try ingestor.ingest(ClipboardCapture(
            capturedAt: fixtureDate,
            content: "baseline searchable fixture",
            sourceApp: sourceApp("Notes"),
            pasteboardTypes: ["public.utf8-plain-text"]
        ))

        var capture = imageCapture(at: fixtureDate.addingTimeInterval(5))
        capture.sourceApp = ClipboardSourceApp(
            name: "Example CRM",
            bundleIdentifier: "com.example.crm"
        )
        let result = try ingestor.ingest(capture)
        guard case let .stored(event, indexUpdate) = result else {
            Issue.record("store-no-index rich capture was not stored")
            return
        }
        // Stored, visible, NEVER searchable — the restricted rich event is
        // never upserted (delete-instead-of-insert; the index has no
        // privacy-label column).
        #expect(event.privacyLabel == .restricted)
        #expect(indexUpdate == .excluded)
        #expect(try index.occurrenceIDs(contentHash: event.contentHash).isEmpty)
        // Still readable through the reader (visible surface).
        let visible = try ClipboardArchiveReader(archiveRoot: root)
            .recentItems(since: .distantPast, limit: 10)
        #expect(visible.contains { $0.id == event.id })
    }

    // MARK: - Index per-kind + parity

    @Test
    func testIndexPerKindBodiesAndUpsertRebuildParity() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let indexURL = try temporaryDirectory().appendingPathComponent("index.sqlite")
        let index = ClipboardDerivedIndex(archiveRoot: root, indexURL: indexURL)
        let ingestor = ClipboardIngestor(
            archiveWriter: ClipboardArchiveWriter(archiveRoot: root),
            derivedIndex: index
        )

        let files = [
            ClipboardRichFileReference(
                name: "invoicefixture.pdf",
                path: "/tmp/secretdirtoken123/invoicefixture.pdf"
            )
        ]
        _ = try ingestor.ingest(imageCapture())
        _ = try ingestor.ingest(fileListCapture(files: files))
        _ = try ingestor.ingest(rtfCapture())
        _ = try ingestor.ingest(colorCapture())
        _ = try ingestor.ingest(linkCapture())

        func hits(_ query: String) throws -> Set<String> {
            Set(try index.structuredSearch(query).map(\.id))
        }

        // Per-kind findability after the incremental upserts.
        #expect(try hits("Image").count == 1)               // image → preview text
        #expect(try hits("invoicefixture").count == 1)      // file NAME
        #expect(try hits("secretdirtoken123").isEmpty)      // NOT by path token
        #expect(try hits("bold").count == 1)                // rtf fallback
        #expect(try hits("3A7BFF").count == 1)              // color hex
        #expect(try hits("Launch Notes Fixture").count == 1) // link title

        let queries = ["Image", "invoicefixture", "secretdirtoken123", "bold", "3A7BFF", "Fixture"]
        let upsertResults = try queries.map { try hits($0) }

        // Rebuild derives bodies through the SAME per-kind derivation —
        // parity by construction, pinned here.
        _ = try index.rebuild()
        let rebuildResults = try queries.map { try hits($0) }
        #expect(upsertResults == rebuildResults)
    }

    // MARK: - Migration / degradation receipts

    @Test
    func testV1LineDecodesWithNilRichContent() throws {
        let event = try archiveDecoder().decode(
            StoredClipboardEvent.self,
            from: Data(SyntheticFixtures.legacyV1Line().utf8)
        )
        #expect(event.schemaVersion == 1)
        #expect(event.richContent == nil)
    }

    @Test
    func testV2ImageLineDecodesAsFirstClassImage() throws {
        // Pinned v2 image line — the shape THIS build writes.
        let line = #"{"allowedUse":["local-search","local-analysis"],"byteCount":70,"capturedAt":"2027-01-15T08:00:00Z","characterCount":0,"contentHash":"sha256:imagefixture","contentPreview":"Image 1×1 (70 bytes)","contentType":"image","id":"clip_20270115T080000Z_imagefixture_cd34ef56","lineCount":1,"pasteboardTypes":["public.png"],"privacyLabel":"private-local","richContent":{"bodyByteCount":70,"bodyPath":"raw/2027/01/2027-01-15_large-items/clip_20270115T080000Z_imagefixture_cd34ef56.png","bodyType":"public.png","hasPlainTextFallback":false,"imagePixelHeight":1,"imagePixelWidth":1,"kind":"image"},"schemaVersion":2,"sensitivityFlags":[],"sourceApp":{"bundleIdentifier":"com.apple.Preview","name":"Preview"},"uiVisibleUntil":"2027-01-22T08:00:00Z"}"#
        let event = try archiveDecoder().decode(StoredClipboardEvent.self, from: Data(line.utf8))
        #expect(event.contentType == .image)
        #expect(event.schemaVersion == 2)
        let rich = try #require(event.richContent)
        #expect(rich.kind == "image")
        #expect(rich.bodyPath?.hasSuffix(".png") == true)
        #expect(rich.imagePixelWidth == 1)

        // Round-trip: the tolerant decode + synthesized encode keep every
        // field (unknown-future-field tolerance is covered by the retargeted
        // futureVersionLine fixture in SchemaVersioningTests).
        let reencoded = try archiveDecoder().decode(
            StoredClipboardEvent.self,
            from: try archiveEncoder().encode(event)
        )
        #expect(reencoded == event)
    }

    @Test
    func testOldBuildFallbackPinContentForImageIsPreviewText() throws {
        // Old builds copy via content(for:), which must resolve to the
        // preview text for images (no inline, no rawContentPath) — the
        // documented degradation.
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let event = try ClipboardArchiveWriter(archiveRoot: root)
            .archiveAllowedCapture(imageCapture())
        let content = try ClipboardArchiveReader(archiveRoot: root).content(for: event)
        #expect(content == event.contentPreview)
        #expect(content.hasPrefix("Image 1×1"))
    }

    // MARK: - Redaction / prune of rich bodies

    @Test
    func testRedactionDeletesRichBodyAndNullsRichContentInTombstone() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let indexURL = try temporaryDirectory().appendingPathComponent("index.sqlite")
        let event = try ClipboardArchiveWriter(archiveRoot: root)
            .archiveAllowedCapture(imageCapture())
        let bodyPath = try #require(event.richContent?.bodyPath)
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent(bodyPath).path))

        let result = try ClipboardArchiveRedactor(archiveRoot: root, indexURL: indexURL)
            .redact(eventID: event.id)

        #expect(result.deletedBodyFile == bodyPath)
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent(bodyPath).path))

        // Tombstone line: richContent nil, preview redacted.
        let dayFile = root.appendingPathComponent("raw/2027/01/2027-01-15_clipboard-events.ndjson")
        let tombstone = try archiveDecoder().decode(
            StoredClipboardEvent.self,
            from: Data(String(contentsOf: dayFile)
                .split(separator: "\n")[0].data(using: .utf8) ?? Data())
        )
        #expect(tombstone.richContent == nil)
        #expect(tombstone.contentPreview == "[deleted]")
        #expect(tombstone.privacyLabel == .doNotIndex)
    }

    @Test
    func testPruneCoreDeletesRichBodiesWithTruthfulDryRunParity() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let indexURL = try temporaryDirectory().appendingPathComponent("index.sqlite")
        let writer = ClipboardArchiveWriter(archiveRoot: root)
        let image = try writer.archiveAllowedCapture(imageCapture())
        _ = try writer.archiveAllowedCapture(rtfCapture())
        let bodyPath = try #require(image.richContent?.bodyPath)
        let pruner = ClipboardArchivePruner(archiveRoot: root, indexURL: indexURL)
        let cutoff = fixtureDate.addingTimeInterval(3_600)

        let dryRun = try pruner.pruneContent(before: cutoff, dryRun: true)
        #expect(dryRun.prunedEvents == 2)
        #expect(dryRun.deletedBodyFiles == 2) // image .png + rtf .rtf
        #expect(dryRun.reclaimedBytes > 0)
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent(bodyPath).path))

        let executed = try pruner.pruneContent(before: cutoff)
        // Truthful preview: dry-run == execute number-for-number.
        #expect(executed.prunedEvents == dryRun.prunedEvents)
        #expect(executed.deletedBodyFiles == dryRun.deletedBodyFiles)
        #expect(executed.reclaimedBytes == dryRun.reclaimedBytes)
        #expect(richBodyFiles(under: root).isEmpty)

        // Tombstones carry no richContent.
        let reader = ClipboardArchiveReader(archiveRoot: root)
        for file in try reader.eventFiles() {
            for line in try String(contentsOf: file).split(separator: "\n") {
                let event = try archiveDecoder().decode(
                    StoredClipboardEvent.self,
                    from: Data(String(line).utf8)
                )
                #expect(event.richContent == nil)
            }
        }
    }

    @Test
    func testWriterDeletesBodiesWhenNDJSONAppendFails() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        // Make the day-file path a DIRECTORY so the append fails after the
        // body write.
        let dayFile = root.appendingPathComponent("raw/2027/01/2027-01-15_clipboard-events.ndjson")
        try FileManager.default.createDirectory(at: dayFile, withIntermediateDirectories: true)

        #expect(throws: (any Error).self) {
            _ = try ClipboardArchiveWriter(archiveRoot: root)
                .archiveAllowedCapture(imageCapture())
        }
        // No orphaned rich body left behind.
        #expect(richBodyFiles(under: root).isEmpty)
    }

    // MARK: - Dedup

    @Test
    func testPerKindDedupValuesMatchCanonicalBytes() throws {
        let data = Self.tinyPNGData()
        let imageA = ClipboardCaptureDedup.value(
            content: "",
            rich: .image(data: data, uti: "public.png", pixelWidth: 1, pixelHeight: 1)
        )
        let imageB = ClipboardCaptureDedup.value(
            content: "",
            rich: .image(data: data, uti: "public.png", pixelWidth: nil, pixelHeight: nil)
        )
        // Same bytes → same dedup value regardless of side metadata.
        #expect(imageA == imageB)
        let differentBytes = ClipboardCaptureDedup.value(
            content: "",
            rich: .image(data: data + Data([0x00]), uti: "public.png", pixelWidth: 1, pixelHeight: 1)
        )
        #expect(imageA != differentBytes)

        // Text dedup unchanged: content hashValue, exactly what the poll
        // and plain copy-back both use.
        #expect(ClipboardCaptureDedup.value(content: "abc", rich: nil) == "abc".hashValue)

        // Link/color/file-list key on their canonical strings.
        let linkValue = ClipboardCaptureDedup.value(
            content: "https://example.com/a\nTitle",
            rich: .link(url: "https://example.com/a", title: "Title")
        )
        let linkValueAgain = ClipboardCaptureDedup.value(
            content: "ignored-for-rich",
            rich: .link(url: "https://example.com/a", title: "Title")
        )
        #expect(linkValue == linkValueAgain)
    }

    @Test
    func testCopyBackDedupPreventsReCaptureOfIdenticalRichContent() throws {
        // Core-level receipt for "copy back + poll tick → no new event":
        // capture-side and copy-back-side values agree for every kind, so
        // the poll's `dedupValue != lastContentHash` guard holds.
        let data = Self.tinyPNGData()
        let capture = imageCapture(data: data)
        let pollValue = ClipboardCaptureDedup.value(content: capture.content, rich: capture.rich)
        // Copy-back recomputes from the STORED body bytes + metadata.
        let copyBackValue = ClipboardCaptureDedup.value(
            content: "",
            rich: .image(data: data, uti: "public.png", pixelWidth: 1, pixelHeight: 1)
        )
        #expect(pollValue == copyBackValue)
    }

    // MARK: - Settings

    @Test
    func testRichSettingsDefaultsAndTolerantDecode() throws {
        // Older settings file: rich keys absent → capture on, default cap.
        let old = Data(#"{"archiveEnabled":true,"recentItemLimit":50}"#.utf8)
        let decoded = try JSONDecoder().decode(ClipboardSettings.self, from: old)
        #expect(decoded.captureRichContent)
        #expect(decoded.richImageMaxBytes == ClipboardSettings.defaultRichImageMaxBytes)

        // Clamping guards hand-edited extremes.
        #expect(ClipboardSettings(richImageMaxBytes: 1).richImageMaxBytes == 64 * 1024)
        #expect(ClipboardSettings(richImageMaxBytes: .max).richImageMaxBytes == 512 * 1024 * 1024)

        // Round-trip of explicit values.
        let custom = ClipboardSettings(captureRichContent: false, richImageMaxBytes: 5 * 1024 * 1024)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let restored = try JSONDecoder().decode(
            ClipboardSettings.self,
            from: try encoder.encode(custom)
        )
        #expect(restored.captureRichContent == false)
        #expect(restored.richImageMaxBytes == 5 * 1024 * 1024)
    }

    // MARK: - Health extensions

    @Test
    func testHealthCountsRichBodiesAndOrphans() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let indexURL = try temporaryDirectory().appendingPathComponent("index.sqlite")
        let writer = ClipboardArchiveWriter(archiveRoot: root)
        _ = try writer.archiveAllowedCapture(imageCapture())
        _ = try writer.archiveAllowedCapture(rtfCapture())

        // One orphaned rich body (what an OLD build's redaction leaves
        // behind when it rewrites a v2 line without richContent).
        let orphan = root.appendingPathComponent("raw/2027/01/2027-01-15_large-items/orphan-fixture.png")
        try Self.tinyPNGData().write(to: orphan)

        let health = try ClipboardArchiveHealthReporter(archiveRoot: root, indexURL: indexURL)
            .health()
        #expect(health.richContentEvents == 2)
        // .png + .rtf bodies + orphan are all counted as body files now.
        #expect(health.largeBodyFiles == 3)
        #expect(health.orphanedRichBodyFiles == 1)
        #expect(health.missingBodyFiles == 0)

        // Deleting a referenced body surfaces as missing, not orphaned.
        let events = try ClipboardArchiveReader(archiveRoot: root)
            .recentItems(since: .distantPast, limit: 10)
        let imageEvent = try #require(events.first { $0.contentType == .image })
        let bodyPath = try #require(imageEvent.richContent?.bodyPath)
        try FileManager.default.removeItem(at: root.appendingPathComponent(bodyPath))
        let afterDelete = try ClipboardArchiveHealthReporter(archiveRoot: root, indexURL: indexURL)
            .health()
        #expect(afterDelete.missingBodyFiles == 1)
    }
}
