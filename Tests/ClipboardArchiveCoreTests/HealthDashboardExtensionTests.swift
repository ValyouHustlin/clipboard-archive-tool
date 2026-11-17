import Foundation
import Testing
@testable import ClipboardArchiveCore

/// Slice 5 health-reporter dashboard extensions and blocked-event
/// explanations. Synthetic fixtures under temp roots only (contract 10).
@Suite("Health Dashboard Extensions")
struct HealthDashboardExtensionTests {
    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("clipboard-health-ext-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test func testExtendedHealthFields() throws {
        let archiveRoot = try temporaryDirectory()
        let indexURL = try temporaryDirectory().appendingPathComponent("index.sqlite")
        let writer = ClipboardArchiveWriter(archiveRoot: archiveRoot, inlineContentLimitBytes: 32)
        let annotations = ClipboardAnnotationsStore(archiveRoot: archiveRoot)

        let oldest = try writer.archiveAllowedCapture(ClipboardCapture(
            capturedAt: Date(timeIntervalSince1970: 1_700_000_000),
            content: "oldest health fixture",
            sourceApp: ClipboardSourceApp(name: "Notes", bundleIdentifier: "com.apple.Notes")
        ))
        let large = try writer.archiveAllowedCapture(ClipboardCapture(
            content: String(repeating: "large health fixture body\n", count: 20),
            sourceApp: ClipboardSourceApp(name: "Notes", bundleIdentifier: "com.apple.Notes")
        ))
        let restricted = try writer.archiveAllowedCapture(
            ClipboardCapture(
                content: "restricted labelled health fixture",
                sourceApp: ClipboardSourceApp(name: "CRM", bundleIdentifier: "com.example.crm")
            ),
            privacyLabel: .restricted
        )
        try annotations.setPinned(true, forContentHash: oldest.contentHash)
        try annotations.setTags(["health"], forContentHash: oldest.contentHash)
        try annotations.setExpiry(Date().addingTimeInterval(3_600), forContentHash: large.contentHash)
        try annotations.setSensitivityOverride("restricted", forContentHash: large.contentHash)
        _ = try ClipboardDerivedIndex(archiveRoot: archiveRoot, indexURL: indexURL).rebuild()

        let health = try ClipboardArchiveHealthReporter(archiveRoot: archiveRoot, indexURL: indexURL)
            .health()
        #expect(health.storedEvents == 3)
        #expect(health.eventFileCount >= 1)
        #expect(health.bodyFileBytes > 0)
        #expect(health.oldestCapturedAt == Date(timeIntervalSince1970: 1_700_000_000))
        // One restricted by label + one by manual override.
        #expect(health.restrictedEvents == 2)
        #expect(health.pinnedItems == 1)
        #expect(health.taggedItems == 1)
        #expect(health.expiringItems == 1)
        #expect(health.indexUserVersion == ClipboardDerivedIndex.currentIndexSchemaVersion)
        #expect(health.annotationsBytes > 0)
        _ = restricted
    }

    @Test func testExtendedFieldsWithEmptyArchive() throws {
        let archiveRoot = try temporaryDirectory()
        let indexURL = try temporaryDirectory().appendingPathComponent("missing.sqlite")
        let health = try ClipboardArchiveHealthReporter(archiveRoot: archiveRoot, indexURL: indexURL)
            .health()
        #expect(health.storedEvents == 0)
        #expect(health.eventFileCount == 0)
        #expect(health.bodyFileBytes == 0)
        #expect(health.oldestCapturedAt == nil)
        #expect(health.restrictedEvents == 0)
        #expect(health.pinnedItems == 0)
        #expect(health.indexUserVersion == nil)
        #expect(health.annotationsBytes == 0)
    }

    @Test func testRecentBlockedEventsReadNewestFirst() throws {
        let archiveRoot = try temporaryDirectory()
        let writer = ClipboardArchiveWriter(archiveRoot: archiveRoot)
        try writer.archiveBlockedCapture(
            ClipboardCapture(
                capturedAt: Date().addingTimeInterval(-120),
                content: "never stored",
                sourceApp: ClipboardSourceApp(name: "Dashlane", bundleIdentifier: "com.dashlane.dashlane")
            ),
            reason: "source_app_denylist:com.dashlane.dashlane"
        )
        try writer.archiveBlockedCapture(
            ClipboardCapture(
                capturedAt: Date().addingTimeInterval(-60),
                content: "never stored either",
                sourceApp: ClipboardSourceApp(name: "CRM", bundleIdentifier: "com.example.crm")
            ),
            reason: "app_rule_block:com.example.crm"
        )
        try writer.archiveAllowedCapture(ClipboardCapture(
            content: "stored line the blocked reader must skip",
            sourceApp: ClipboardSourceApp(name: "Notes", bundleIdentifier: "com.apple.Notes")
        ))

        let blocked = try ClipboardArchiveReader(archiveRoot: archiveRoot)
            .recentBlockedEvents(since: .distantPast, limit: 10)
        #expect(blocked.count == 2)
        #expect(blocked.first?.reason == "app_rule_block:com.example.crm")
        #expect(blocked.allSatisfy { $0.contentStored == false })

        let limited = try ClipboardArchiveReader(archiveRoot: archiveRoot)
            .recentBlockedEvents(since: .distantPast, limit: 1)
        #expect(limited.count == 1)
    }

    @Test func testBlockedEventExplanations() throws {
        #expect(ClipboardBlockedEventExplainer.explanation(
            for: "pasteboard_type_denylist:org.nspasteboard.ConcealedType"
        ).contains("concealed or transient"))
        #expect(ClipboardBlockedEventExplainer.explanation(
            for: "source_app_denylist:com.1password.1password"
        ).contains("password manager"))
        #expect(ClipboardBlockedEventExplainer.explanation(
            for: "source_app_denylist:com.example.custom"
        ).contains("excluded in Settings"))
        #expect(ClipboardBlockedEventExplainer.explanation(
            for: "source_app_name_denylist:keychain access"
        ).contains("password manager"))
        #expect(ClipboardBlockedEventExplainer.explanation(
            for: "app_rule_block:com.example.crm"
        ).contains("app privacy rule"))
        #expect(ClipboardBlockedEventExplainer.explanation(
            for: "secret_detector:private-key,env-secret-assignment"
        ).contains("credential"))
        // Unknown reasons fall back without crashing or hiding the raw text.
        #expect(ClipboardBlockedEventExplainer.explanation(
            for: "novel_reason:whatever"
        ).contains("novel_reason:whatever"))
        #expect(ClipboardBlockedEventExplainer.shortLabel(
            for: "source_app_denylist:com.1password.1password"
        ) == "password manager rule")
        #expect(ClipboardBlockedEventExplainer.shortLabel(
            for: "app_rule_block:com.example.crm"
        ) == "app privacy rule")
    }
}
