import ClipboardArchiveCore
import Foundation

enum CheckFailure: Error, CustomStringConvertible {
    case failed(String)

    var description: String {
        switch self {
        case let .failed(message):
            return message
        }
    }
}

func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    if !condition() {
        throw CheckFailure.failed(message)
    }
}

func run(_ name: String, _ body: () throws -> Void) rethrows {
    try body()
    print("ok - \(name)")
}

func temporaryDirectory() -> URL {
    URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("clipboard-archive-checks-\(UUID().uuidString)")
}

do {
    try run("detects private key") {
        let privateKeyHeader = "-----BEGIN " + "PRIVATE KEY-----"
        let privateKeyFooter = "-----END " + "PRIVATE KEY-----"
        let result = SecretDetector().inspect("""
        \(privateKeyHeader)
        abcdef
        \(privateKeyFooter)
        """)
        try expect(result.isSensitive, "private key should be sensitive")
        try expect(result.flags.contains("private-key"), "missing private-key flag")
    }

    try run("detects env secret assignment") {
        let result = SecretDetector().inspect("OPENAI_API_KEY=" + "sk-" + "abcdefghijklmnopqrstuvwxyz123456")
        try expect(result.isSensitive, "env secret should be sensitive")
        try expect(result.flags.contains("env-secret-assignment"), "missing env-secret-assignment flag")
    }

    try run("allows ordinary url") {
        let result = SecretDetector().inspect("https://example.com/research/article?topic=clipboard")
        try expect(!result.isSensitive, "ordinary URL should be allowed")
    }

    try run("blocks known password manager bundle") {
        let filter = ClipboardPrivacyFilter()
        let capture = ClipboardCapture(
            content: "ordinary-looking-text",
            sourceApp: ClipboardSourceApp(name: "Dashlane", bundleIdentifier: "com.dashlane.dashlane")
        )
        guard case let .block(reason) = filter.evaluate(capture) else {
            throw CheckFailure.failed("expected Dashlane capture to be blocked")
        }
        try expect(reason.contains("source_app_denylist"), "missing source app denylist reason")
    }

    try run("blocks secret content from allowed app") {
        let filter = ClipboardPrivacyFilter()
        let capture = ClipboardCapture(
            content: "GITHUB_TOKEN=" + "ghp_" + "abcdefghijklmnopqrstuvwxyz123456789",
            sourceApp: ClipboardSourceApp(name: "Notes", bundleIdentifier: "com.apple.Notes")
        )
        guard case let .block(reason) = filter.evaluate(capture) else {
            throw CheckFailure.failed("expected token capture to be blocked")
        }
        try expect(reason.contains("secret_detector"), "missing secret detector reason")
    }

    try run("allows normal code snippet") {
        let filter = ClipboardPrivacyFilter()
        let capture = ClipboardCapture(
            content: "func greet() {\n    print(\"hello\")\n}",
            sourceApp: ClipboardSourceApp(name: "Cursor", bundleIdentifier: "com.todesktop.230313mzl4w4u92")
        )
        try expect(filter.evaluate(capture) == .allow(sensitivityFlags: []), "normal code should be allowed")
    }

    try run("archives small event inline with seven-day UI window") {
        let root = temporaryDirectory()
        let writer = ClipboardArchiveWriter(archiveRoot: root, inlineContentLimitBytes: 1024)
        let capturedAt = Date(timeIntervalSince1970: 1_800_000_000)
        let capture = ClipboardCapture(
            capturedAt: capturedAt,
            content: "https://example.com/a-useful-link",
            sourceApp: ClipboardSourceApp(name: "Safari", bundleIdentifier: "com.apple.Safari"),
            pasteboardTypes: ["public.utf8-plain-text"]
        )

        let event = try writer.archiveAllowedCapture(capture)

        try expect(event.contentType == .url, "expected URL content type")
        try expect(event.contentInline == capture.content, "expected inline content")
        try expect(event.rawContentPath == nil, "small event should not have body file")
        try expect(event.privacyLabel == .privateLocal, "expected private-local label")
        try expect(event.allowedUse == [.localSearch, .localAnalysis], "expected local allowed uses")
        try expect(event.uiVisibleUntil.timeIntervalSince(capturedAt) == 7 * 24 * 60 * 60, "expected 7-day UI window")

        let archiveFile = root
            .appendingPathComponent("raw/2027/01/2027-01-15_clipboard-events.ndjson")
        try expect(FileManager.default.fileExists(atPath: archiveFile.path), "missing daily archive file")
    }

    try run("archives large event to separate body file") {
        let root = temporaryDirectory()
        let writer = ClipboardArchiveWriter(archiveRoot: root, inlineContentLimitBytes: 16)
        let capture = ClipboardCapture(
            capturedAt: Date(timeIntervalSince1970: 1_800_000_000),
            content: "func example() {\n    print(\"large enough\")\n}",
            sourceApp: ClipboardSourceApp(name: "Cursor")
        )

        let event = try writer.archiveAllowedCapture(capture)

        try expect(event.contentInline == nil, "large event should not be inline")
        guard let bodyPath = event.rawContentPath else {
            throw CheckFailure.failed("missing large event body path")
        }
        try expect(FileManager.default.fileExists(atPath: root.appendingPathComponent(bodyPath).path), "missing large body file")
    }

    try run("archives blocked event without content") {
        let root = temporaryDirectory()
        let writer = ClipboardArchiveWriter(archiveRoot: root)
        let capture = ClipboardCapture(
            capturedAt: Date(timeIntervalSince1970: 1_800_000_000),
            content: "secret",
            sourceApp: ClipboardSourceApp(name: "Dashlane")
        )

        try writer.archiveBlockedCapture(capture, reason: "source_app_denylist:dashlane")

        let archiveFile = root
            .appendingPathComponent("raw/2027/01/2027-01-15_clipboard-events.ndjson")
        let contents = try String(contentsOf: archiveFile)
        try expect(contents.contains("blocked_sensitive_clipboard_item"), "missing blocked audit event")
        try expect(!contents.contains("secret\n"), "blocked event leaked content")
    }

    try run("searches inline and large archived content") {
        let root = temporaryDirectory()
        let writer = ClipboardArchiveWriter(archiveRoot: root, inlineContentLimitBytes: 16)
        _ = try writer.archiveAllowedCapture(ClipboardCapture(
            capturedAt: Date(timeIntervalSince1970: 1_800_000_000),
            content: "short note about alpha-search-token",
            sourceApp: ClipboardSourceApp(name: "Notes")
        ))
        _ = try writer.archiveAllowedCapture(ClipboardCapture(
            capturedAt: Date(timeIntervalSince1970: 1_800_000_010),
            content: "func example() {\n" + String(repeating: "    let filler = 1\n", count: 40) + "    print(\"beta-large-search-token\")\n}",
            sourceApp: ClipboardSourceApp(name: "Cursor")
        ))

        let searcher = ClipboardArchiveSearcher(archiveRoot: root)
        let inlineResults = try searcher.search(ClipboardSearchOptions(query: "alpha-search-token"))
        let bodyResults = try searcher.search(ClipboardSearchOptions(query: "beta-large-search-token"))

        try expect(inlineResults.count == 1, "expected one inline search result")
        try expect(!inlineResults[0].matchedInBody, "inline result should match metadata/content line")
        try expect(bodyResults.count == 1, "expected one large body search result")
        try expect(bodyResults[0].matchedInBody, "large result should match body file")
    }

    try run("deletion ledger hides recent and search results") {
        let root = temporaryDirectory()
        let writer = ClipboardArchiveWriter(archiveRoot: root)
        let event = try writer.archiveAllowedCapture(ClipboardCapture(
            capturedAt: Date(),
            content: "delete-me-search-token",
            sourceApp: ClipboardSourceApp(name: "Notes")
        ))

        try ClipboardDeletionLedger(archiveRoot: root).recordDeletion(eventID: event.id)

        let recent = try ClipboardArchiveReader(archiveRoot: root)
            .recentItems(since: Date(timeIntervalSince1970: 0), limit: 10)
        let results = try ClipboardArchiveSearcher(archiveRoot: root)
            .search(ClipboardSearchOptions(query: "delete-me-search-token"))

        try expect(recent.isEmpty, "deleted event should be hidden from recent items")
        try expect(results.isEmpty, "deleted event should be hidden from search")
    }

    try run("redaction removes inline and large body content") {
        let root = temporaryDirectory()
        let writer = ClipboardArchiveWriter(archiveRoot: root, inlineContentLimitBytes: 16)
        let inlineEvent = try writer.archiveAllowedCapture(ClipboardCapture(
            capturedAt: Date(),
            content: "inline delete searchable phrase",
            sourceApp: ClipboardSourceApp(name: "Notes")
        ))
        let largeEvent = try writer.archiveAllowedCapture(ClipboardCapture(
            capturedAt: Date(),
            content: String(repeating: "large delete searchable phrase\n", count: 20),
            sourceApp: ClipboardSourceApp(name: "Cursor")
        ))
        let bodyPath = largeEvent.rawContentPath

        try ClipboardArchiveRedactor(archiveRoot: root).redact(eventID: inlineEvent.id)
        try ClipboardArchiveRedactor(archiveRoot: root).redact(eventID: largeEvent.id)

        let searcher = ClipboardArchiveSearcher(archiveRoot: root)
        let inlineResults = try searcher.search(ClipboardSearchOptions(query: "inline delete searchable phrase"))
        let largeResults = try searcher.search(ClipboardSearchOptions(query: "large delete searchable phrase"))

        try expect(inlineResults.isEmpty, "redacted inline content should not be searchable")
        try expect(largeResults.isEmpty, "redacted large content should not be searchable")
        if let bodyPath {
            try expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent(bodyPath).path), "redacted body file should be removed")
        }
    }

    try run("event ids remain unique for identical same-second content") {
        let root = temporaryDirectory()
        let writer = ClipboardArchiveWriter(archiveRoot: root)
        let capturedAt = Date(timeIntervalSince1970: 1_800_000_000)
        let first = try writer.archiveAllowedCapture(ClipboardCapture(
            capturedAt: capturedAt,
            content: "same content same second",
            sourceApp: ClipboardSourceApp(name: "Notes")
        ))
        let second = try writer.archiveAllowedCapture(ClipboardCapture(
            capturedAt: capturedAt,
            content: "same content same second",
            sourceApp: ClipboardSourceApp(name: "Notes")
        ))

        try expect(first.id != second.id, "identical same-second events should not collide")
    }

    try run("archive root defaults to per-user application support") {
        let root = ClipboardDefaults.archiveRoot(environment: [:])
        try expect(root.path.hasSuffix("Library/Application Support/ClipboardArchive/Archive/clipboard-history"), "expected portable application support default")
    }

    try run("default archive root can be overridden by environment") {
        let root = ClipboardDefaults.archiveRoot(environment: ["CLIPBOARD_ARCHIVE_ARCHIVE_ROOT": "/tmp/custom-clipboard-root"])
        try expect(root.path == "/tmp/custom-clipboard-root", "expected environment archive root override")
    }

    try run("default index path can be overridden by environment") {
        let index = ClipboardDefaults.indexURL(environment: ["CLIPBOARD_ARCHIVE_INDEX_PATH": "/tmp/custom-clipboard-index.sqlite"])
        try expect(index.path == "/tmp/custom-clipboard-index.sqlite", "expected environment index path override")
    }

    try run("settings exclusions block configured apps") {
        let settings = ClipboardSettings(
            excludedBundleIdentifiers: ["com.example.Blocked"],
            excludedAppNameFragments: ["blocked fragment"]
        )
        let filter = ClipboardPrivacyFilter(settings: settings)
        let byBundle = ClipboardCapture(
            content: "normal text",
            sourceApp: ClipboardSourceApp(name: "Normal", bundleIdentifier: "com.example.Blocked")
        )
        let byName = ClipboardCapture(
            content: "normal text",
            sourceApp: ClipboardSourceApp(name: "Blocked Fragment App")
        )

        guard case .block = filter.evaluate(byBundle) else {
            throw CheckFailure.failed("configured bundle exclusion did not block")
        }
        guard case .block = filter.evaluate(byName) else {
            throw CheckFailure.failed("configured name exclusion did not block")
        }
    }

    try run("settings clamp recent item limit") {
        let low = ClipboardSettings(recentItemLimit: 1)
        let high = ClipboardSettings(recentItemLimit: 10_000)
        try expect(low.recentItemLimit == 5, "expected low recent limit clamp")
        try expect(high.recentItemLimit == 10_000, "expected high recent limit to be allowed")
        let tooHigh = ClipboardSettings(recentItemLimit: 50_000)
        try expect(tooHigh.recentItemLimit == 10_000, "expected extreme recent limit clamp")
    }

    try run("settings decode older files with new defaults") {
        let data = """
        {
          "excludedBundleIdentifiers": ["com.example.App"],
          "excludedAppNameFragments": [],
          "pollIntervalSeconds": 0.25
        }
        """.data(using: .utf8)!
        let settings = try JSONDecoder().decode(ClipboardSettings.self, from: data)
        try expect(settings.archiveEnabled, "older settings should default archive tracking on")
        try expect(settings.recentItemLimit == 50, "older settings should default visible item count")
    }

    try run("derived sqlite index rebuilds and searches") {
        let root = temporaryDirectory()
        let indexURL = temporaryDirectory().appendingPathComponent("clipboard-search.sqlite")
        let writer = ClipboardArchiveWriter(archiveRoot: root)
        _ = try writer.archiveAllowedCapture(ClipboardCapture(
            capturedAt: Date(),
            content: "sqlite derived index search phrase",
            sourceApp: ClipboardSourceApp(name: "Notes")
        ))

        let index = ClipboardDerivedIndex(archiveRoot: root, indexURL: indexURL)
        let count = try index.rebuild()
        let output = try index.search("sqlite derived index search phrase", limit: 1)

        try expect(count == 1, "expected one indexed item")
        try expect(output.contains("sqlite"), "expected derived index search result")
    }

    try run("redaction purges derived sqlite index") {
        let root = temporaryDirectory()
        let indexURL = temporaryDirectory().appendingPathComponent("clipboard-search.sqlite")
        let writer = ClipboardArchiveWriter(archiveRoot: root)
        let event = try writer.archiveAllowedCapture(ClipboardCapture(
            capturedAt: Date(),
            content: "sqlite redaction purge search phrase",
            sourceApp: ClipboardSourceApp(name: "Notes")
        ))
        let index = ClipboardDerivedIndex(archiveRoot: root, indexURL: indexURL)
        _ = try index.rebuild()
        let outputBeforeRedaction = try index.search("sqlite redaction purge search phrase", limit: 1)
        try expect(outputBeforeRedaction.contains("sqlite"), "expected indexed content before redaction")

        let result = try ClipboardArchiveRedactor(archiveRoot: root, indexURL: indexURL).redact(eventID: event.id)
        let output = try index.search("sqlite redaction purge search phrase", limit: 1)

        try expect(result.deletedFromIndex, "expected redaction to delete from existing derived index")
        try expect(output.isEmpty, "redacted content should be purged from derived index")
    }

    try run("prune redacts old content and rebuilds derived index") {
        let root = temporaryDirectory()
        let indexURL = temporaryDirectory().appendingPathComponent("clipboard-search.sqlite")
        let writer = ClipboardArchiveWriter(archiveRoot: root, inlineContentLimitBytes: 16)
        _ = try writer.archiveAllowedCapture(ClipboardCapture(
            capturedAt: Date(timeIntervalSince1970: 1_700_000_000),
            content: "old prune searchable phrase",
            sourceApp: ClipboardSourceApp(name: "Notes")
        ))
        let oldLargeEvent = try writer.archiveAllowedCapture(ClipboardCapture(
            capturedAt: Date(timeIntervalSince1970: 1_700_000_010),
            content: String(repeating: "old large prune searchable phrase\n", count: 20),
            sourceApp: ClipboardSourceApp(name: "Cursor")
        ))
        _ = try writer.archiveAllowedCapture(ClipboardCapture(
            capturedAt: Date(timeIntervalSince1970: 1_800_000_000),
            content: "new keep searchable phrase",
            sourceApp: ClipboardSourceApp(name: "Notes")
        ))
        let oldLargeBodyPath = oldLargeEvent.rawContentPath
        let index = ClipboardDerivedIndex(archiveRoot: root, indexURL: indexURL)
        _ = try index.rebuild()

        let dryRun = try ClipboardArchivePruner(archiveRoot: root, indexURL: indexURL)
            .pruneContent(before: Date(timeIntervalSince1970: 1_750_000_000), dryRun: true)
        let dryRunSearch = try ClipboardArchiveSearcher(archiveRoot: root)
            .search(ClipboardSearchOptions(query: "old prune searchable phrase"))
        try expect(dryRun.prunedEvents == 2, "expected dry run to count two old events")
        try expect(!dryRunSearch.isEmpty, "dry run should not delete old event")

        let result = try ClipboardArchivePruner(archiveRoot: root, indexURL: indexURL)
            .pruneContent(before: Date(timeIntervalSince1970: 1_750_000_000))

        try expect(result.scannedEvents == 3, "expected three scanned prune events")
        try expect(result.prunedEvents == 2, "expected two pruned events")
        try expect(result.deletedBodyFiles == 2, "expected two pruned body files")
        let searcher = ClipboardArchiveSearcher(archiveRoot: root)
        let oldInlineResults = try searcher.search(ClipboardSearchOptions(query: "old prune searchable phrase"))
        let oldLargeResults = try searcher.search(ClipboardSearchOptions(query: "old large prune searchable phrase"))
        let oldIndexResults = try index.search("old prune searchable phrase", limit: 1)
        let newIndexResults = try index.search("new keep searchable phrase", limit: 1)
        try expect(oldInlineResults.isEmpty, "old inline content should be pruned from archive search")
        try expect(oldLargeResults.isEmpty, "old large content should be pruned from archive search")
        try expect(oldIndexResults.isEmpty, "old inline content should be pruned from derived index")
        try expect(newIndexResults.contains("new keep"), "new content should remain indexed")
        if let oldLargeBodyPath {
            try expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent(oldLargeBodyPath).path), "old large body file should be deleted")
        }
    }

    print("all checks passed")
} catch {
    FileHandle.standardError.write(Data("check failed: \(error)\n".utf8))
    exit(1)
}
