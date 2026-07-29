import Foundation
import Testing
@testable import ClipboardArchiveCore

@Suite("Clipboard Archive Core")
struct ClipboardArchiveCoreTests {
    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("clipboard-archive-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func writeEvent(_ event: StoredClipboardEvent, archiveRoot: URL) throws -> URL {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy/MM/yyyy-MM-dd"
        let relative = "raw/\(formatter.string(from: event.capturedAt))_clipboard-events.ndjson"
        let url = archiveRoot.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        var data = try encoder.encode(event)
        data.append(0x0A)
        try data.write(to: url)
        return url
    }

    private func syntheticExternalBodyEvent(id: String = "synthetic_escape") -> StoredClipboardEvent {
        StoredClipboardEvent(
            id: id,
            capturedAt: Date(),
            contentType: .text,
            contentHash: "sha256:synthetic",
            contentPreview: "synthetic preview",
            contentInline: nil,
            rawContentPath: "../outside.txt",
            sourceApp: ClipboardSourceApp(name: "Synthetic Test"),
            pasteboardTypes: ["public.utf8-plain-text"],
            byteCount: 26,
            characterCount: 26,
            lineCount: 1,
            privacyLabel: .privateLocal,
            allowedUse: [.localSearch],
            sensitivityFlags: [],
            uiVisibleUntil: Date().addingTimeInterval(86_400)
        )
    }

    @Test
    func testFutureEventsAreNotCountedInCurrentHealthWindows() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let now = Date()
        let future = Calendar.current.date(byAdding: .minute, value: 30, to: now)!
        _ = try ClipboardArchiveWriter(archiveRoot: root).archiveAllowedCapture(
            ClipboardCapture(
                capturedAt: future,
                content: "synthetic future health fixture",
                sourceApp: ClipboardSourceApp(name: "Synthetic Test")
            )
        )

        let health = try ClipboardArchiveHealthReporter(
            archiveRoot: root,
            indexURL: root.appendingPathComponent("index.sqlite")
        ).health()

        #expect(health.todayStoredEvents == 0)
        #expect(health.lastSevenDaysStoredEvents == 0)
    }

    @Test
    func testReaderRejectsBodyPathOutsideArchiveRoot() throws {
        let container = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: container) }
        let root = container.appendingPathComponent("archive", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let outside = container.appendingPathComponent("outside.txt")
        try Data("synthetic outside sentinel".utf8).write(to: outside)

        let event = syntheticExternalBodyEvent()

        #expect(throws: (any Error).self) {
            try ClipboardArchiveReader(archiveRoot: root).content(for: event)
        }
    }

    @Test
    func testDailyManifestContainsOnlyRequestedDayCounts() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let calendar = Calendar(identifier: .gregorian)
        let targetDay = ISO8601DateFormatter().date(from: "2026-07-20T12:00:00Z")!
        let otherDay = calendar.date(byAdding: .day, value: 1, to: targetDay)!
        let writer = ClipboardArchiveWriter(archiveRoot: root)
        _ = try writer.archiveAllowedCapture(ClipboardCapture(
            capturedAt: targetDay,
            content: "synthetic target-day event",
            sourceApp: ClipboardSourceApp(name: "Synthetic Test")
        ))
        _ = try writer.archiveAllowedCapture(ClipboardCapture(
            capturedAt: otherDay,
            content: "synthetic other-day event",
            sourceApp: ClipboardSourceApp(name: "Synthetic Test")
        ))

        let reporter = ClipboardArchiveHealthReporter(
            archiveRoot: root,
            indexURL: root.appendingPathComponent("index.sqlite")
        )
        let manifestURL = try reporter.writeDailyManifest(for: targetDay)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let manifest = try decoder.decode(ClipboardDailyManifest.self, from: Data(contentsOf: manifestURL))

        #expect(manifest.storedEvents == 1)
    }

    @Test
    func testNewSettingsDefaultToCaptureOffAndLimitedRetention() {
        let settings = ClipboardSettings()

        #expect(!settings.archiveEnabled)
        #expect(settings.retentionMode == .recent50)
    }

    @Test
    func testBearerTokenIsDetected() {
        let detection = SecretDetector().inspect(
            "Authorization: Bearer synthetic0123456789abcdefghijklmnopqrstuvwxyz"
        )

        #expect(detection.isSensitive)
        #expect(detection.flags.contains("authorization-bearer"))
    }

    @Test
    func testCommonCredentialFormatsAreDetected() {
        let syntheticCredentials = [
            "glpat-synthetic0123456789ABCDEFG",
            "sk-ant-synthetic0123456789abcdefghijklmnop",
            "sk_live_synthetic0123456789ABCD",
            "xoxb-synthetic-0123456789-ABCDEFGHIJK",
            "npm_synthetic0123456789ABCDEFGHIJ",
            "AIzaSySynthetic0123456789abcdefghijkl",
            "password: synthetic-long-password",
            "postgresql://synthetic:long-password@localhost/database"
        ]

        for credential in syntheticCredentials {
            #expect(
                SecretDetector().inspect(credential).isSensitive,
                "Expected synthetic credential format to be blocked: \(credential.prefix(12))"
            )
        }
    }

    @Test
    func testOrdinaryWorkTextIsNotDetectedAsSecret() {
        let ordinaryValues = [
            "https://example.com/research/article?topic=clipboard",
            "func greet() {\n    print(\"hello\")\n}",
            "The API design needs a key decision before Friday.",
            "Clipboard Archive keeps the latest 50 items locally."
        ]

        for value in ordinaryValues {
            #expect(!SecretDetector().inspect(value).isSensitive)
        }
    }

    @Test
    func testKnownPasswordManagerSourcesAreBlocked() {
        let bundles = [
            "com.1password.1password",
            "com.bitwarden.desktop",
            "com.lastpass.lastpass",
            "org.keepassxc.keepassxc",
            "com.protonpass.macos",
            "com.apple.passwords"
        ]

        for bundle in bundles {
            let capture = ClipboardCapture(
                content: "synthetic ordinary-looking value",
                sourceApp: ClipboardSourceApp(name: "Synthetic Password Manager", bundleIdentifier: bundle)
            )
            guard case .block = ClipboardPrivacyFilter().evaluate(capture) else {
                Issue.record("Expected \(bundle) to be blocked")
                continue
            }
        }
    }

    @Test
    func testConfidentialPasteboardTypesAreBlocked() throws {
        let confidentialTypes = [
            "org.nspasteboard.ConcealedType",
            "org.nspasteboard.TransientType",
            "com.agilebits.onepassword"
        ]

        for pasteboardType in confidentialTypes {
            let capture = ClipboardCapture(
                content: "synthetic ordinary-looking value",
                sourceApp: ClipboardSourceApp(name: "Synthetic Unknown App"),
                pasteboardTypes: ["public.utf8-plain-text", pasteboardType]
            )
            guard case .block = ClipboardPrivacyFilter().evaluate(capture) else {
                Issue.record("Expected \(pasteboardType) to be blocked")
                continue
            }
        }

        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let syntheticConfidentialValue = "synthetic concealed value must not persist"
        let capture = ClipboardCapture(
            content: syntheticConfidentialValue,
            sourceApp: ClipboardSourceApp(name: "Synthetic Unknown App"),
            pasteboardTypes: ["public.utf8-plain-text", "org.nspasteboard.ConcealedType"]
        )
        let result = try ClipboardIngestor(
            archiveWriter: ClipboardArchiveWriter(archiveRoot: root)
        ).ingest(capture)
        guard case .blocked = result else {
            Issue.record("Expected concealed synthetic capture to be blocked")
            return
        }
        let eventFile = try #require(ClipboardArchiveReader(archiveRoot: root).eventFiles().first)
        let payload = try String(contentsOf: eventFile)
        #expect(!payload.contains(syntheticConfidentialValue))
    }

    @Test
    func testBlockedCaptureDoesNotPersistRawContent() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let syntheticSecret = "Authorization: Bearer synthetic0123456789abcdefghijklmnopqrstuvwxyz"
        let capture = ClipboardCapture(
            content: syntheticSecret,
            sourceApp: ClipboardSourceApp(name: "Synthetic Test")
        )

        let result = try ClipboardIngestor(
            archiveWriter: ClipboardArchiveWriter(archiveRoot: root)
        ).ingest(capture)

        guard case .blocked = result else {
            Issue.record("Expected synthetic bearer token to be blocked")
            return
        }
        let eventFile = try #require(ClipboardArchiveReader(archiveRoot: root).eventFiles().first)
        let payload = try String(contentsOf: eventFile)
        #expect(!payload.contains(syntheticSecret))
        #expect(payload.contains("\"contentStored\":false"))
    }

    @Test
    func testArchiveWriterUsesPrivateFilePermissions() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let event = try ClipboardArchiveWriter(
            archiveRoot: root,
            inlineContentLimitBytes: 8
        ).archiveAllowedCapture(ClipboardCapture(
            content: "synthetic large body fixture",
            sourceApp: ClipboardSourceApp(name: "Synthetic Test")
        ))

        let eventFile = try #require(ClipboardArchiveReader(archiveRoot: root).eventFiles().first)
        let bodyPath = try #require(event.rawContentPath)
        let bodyFile = try ClipboardArchivePath.containedURL(relativePath: bodyPath, archiveRoot: root)
        let eventMode = try #require(
            FileManager.default.attributesOfItem(atPath: eventFile.path)[.posixPermissions] as? NSNumber
        )
        let bodyMode = try #require(
            FileManager.default.attributesOfItem(atPath: bodyFile.path)[.posixPermissions] as? NSNumber
        )

        #expect(eventMode.intValue == 0o600)
        #expect(bodyMode.intValue == 0o600)
    }

    @Test
    func testExistingIndexParentPermissionsAreNotChanged() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let sharedParent = root.appendingPathComponent("synthetic-shared-parent", isDirectory: true)
        try FileManager.default.createDirectory(at: sharedParent, withIntermediateDirectories: true)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: Int16(0o755))],
            ofItemAtPath: sharedParent.path
        )
        _ = try ClipboardArchiveWriter(archiveRoot: root).archiveAllowedCapture(
            ClipboardCapture(
                content: "synthetic index parent fixture",
                sourceApp: ClipboardSourceApp(name: "Synthetic Test")
            )
        )

        _ = try ClipboardDerivedIndex(
            archiveRoot: root,
            indexURL: sharedParent.appendingPathComponent("search.sqlite")
        ).rebuild()

        let mode = try #require(
            FileManager.default.attributesOfItem(atPath: sharedParent.path)[.posixPermissions] as? NSNumber
        )
        #expect(mode.intValue == 0o755)
    }

    @Test
    func testSymlinkEscapeIsRejected() throws {
        let container = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: container) }
        let root = container.appendingPathComponent("archive", isDirectory: true)
        let outside = container.appendingPathComponent("outside", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent("linked"),
            withDestinationURL: outside
        )

        #expect(throws: (any Error).self) {
            try ClipboardArchivePath.containedURL(
                relativePath: "linked/synthetic.txt",
                archiveRoot: root
            )
        }
    }

    @Test
    func testWriterRejectsSymlinkedArchiveSubdirectory() throws {
        let container = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: container) }
        let root = container.appendingPathComponent("archive", isDirectory: true)
        let outside = container.appendingPathComponent("outside", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent("raw"),
            withDestinationURL: outside
        )

        #expect(throws: (any Error).self) {
            try ClipboardArchiveWriter(archiveRoot: root).archiveAllowedCapture(
                ClipboardCapture(
                    content: "synthetic writer symlink fixture",
                    sourceApp: ClipboardSourceApp(name: "Synthetic Test")
                )
            )
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: outside.path).isEmpty)
    }

    @Test
    func testRedactionNeverDeletesOutsideArchiveRoot() throws {
        let container = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: container) }
        let root = container.appendingPathComponent("archive", isDirectory: true)
        let outside = container.appendingPathComponent("outside.txt")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("synthetic outside sentinel".utf8).write(to: outside)
        let event = syntheticExternalBodyEvent(id: "synthetic_redaction_escape")
        _ = try writeEvent(event, archiveRoot: root)

        let result = try ClipboardArchiveRedactor(
            archiveRoot: root,
            indexURL: root.appendingPathComponent("index.sqlite")
        ).redact(eventID: event.id)

        #expect(result.skippedUnsafeBodyPath)
        #expect(FileManager.default.fileExists(atPath: outside.path))
        #expect(try String(contentsOf: outside) == "synthetic outside sentinel")
    }

    @Test
    func testHealthReportsUnsafeBodyPaths() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try writeEvent(syntheticExternalBodyEvent(), archiveRoot: root)

        let health = try ClipboardArchiveHealthReporter(
            archiveRoot: root,
            indexURL: root.appendingPathComponent("index.sqlite")
        ).health()

        #expect(health.unsafeBodyPaths == 1)
        #expect(health.missingBodyFiles == 0)
    }

    @Test
    func testFailedIndexRebuildPreservesExistingIndex() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let indexURL = root.appendingPathComponent("existing.sqlite")
        let original = Data("synthetic existing index".utf8)
        try original.write(to: indexURL)
        _ = try ClipboardArchiveWriter(archiveRoot: root).archiveAllowedCapture(
            ClipboardCapture(
                content: "synthetic index fixture",
                sourceApp: ClipboardSourceApp(name: "Synthetic Test")
            )
        )

        #expect(throws: (any Error).self) {
            try ClipboardDerivedIndex(
                archiveRoot: root,
                indexURL: indexURL,
                sqliteExecutableURL: URL(fileURLWithPath: "/usr/bin/false")
            ).rebuild()
        }
        #expect(try Data(contentsOf: indexURL) == original)
    }

    @Test
    func testIndexRebuildAndSearchRoundTrip() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let indexURL = root.appendingPathComponent("indexes/search.sqlite")
        _ = try ClipboardArchiveWriter(archiveRoot: root).archiveAllowedCapture(
            ClipboardCapture(
                content: "synthetic sqlite round trip phrase",
                sourceApp: ClipboardSourceApp(name: "Synthetic Test")
            )
        )
        let index = ClipboardDerivedIndex(archiveRoot: root, indexURL: indexURL)

        #expect(try index.rebuild() == 1)
        let output = try index.search("sqlite round trip")
        #expect(output.contains("round trip"))
        #expect(output.contains("Synthetic Test"))
        let mode = try #require(
            FileManager.default.attributesOfItem(atPath: indexURL.path)[.posixPermissions] as? NSNumber
        )
        #expect(mode.intValue == 0o600)
    }

    @Test
    func testLegacySettingsCompleteOnboardingWithoutChangingCapture() throws {
        let data = Data("""
        {
          "archiveEnabled": true,
          "recentItemLimit": 50,
          "retentionMode": "unlimited",
          "pollIntervalSeconds": 0.2
        }
        """.utf8)
        let settings = try JSONDecoder().decode(ClipboardSettings.self, from: data)

        #expect(settings.archiveEnabled)
        #expect(settings.retentionMode == .unlimited)
        #expect(settings.hasCompletedOnboarding)
    }

    @Test
    func testApplicationSupportRootCanBeIsolated() {
        let root = ClipboardDefaults.applicationSupportRoot(
            environment: [ClipboardDefaults.applicationSupportEnvironmentKey: "/tmp/synthetic-app-support"]
        )

        #expect(root.path == "/tmp/synthetic-app-support")
        #expect(
            ClipboardDefaults.settingsURL(
                environment: [ClipboardDefaults.applicationSupportEnvironmentKey: "/tmp/synthetic-app-support"]
            ).path == "/tmp/synthetic-app-support/settings.json"
        )
        #expect(
            ClipboardDefaults.lockURL(
                environment: [ClipboardDefaults.applicationSupportEnvironmentKey: "/tmp/synthetic-app-support"]
            ).path == "/tmp/synthetic-app-support/ClipboardArchive.lock"
        )
        #expect(
            ClipboardDefaults.userDefaultsSuiteName(
                environment: [ClipboardDefaults.applicationSupportEnvironmentKey: "/tmp/synthetic-app-support"]
            ) == ClipboardDefaults.isolatedUserDefaultsSuiteName
        )
        #expect(ClipboardDefaults.userDefaultsSuiteName(environment: [:]) == nil)
    }
}
