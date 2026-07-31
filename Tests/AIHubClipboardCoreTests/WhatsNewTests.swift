import Foundation
import Testing
@testable import ClipboardArchiveCore

@Suite("What's New Gate")
struct WhatsNewTests {
    // MARK: - Tolerant settings decode (contract 4)

    @Test
    func testMissingLastSeenAppVersionDecodesAsEmpty() throws {
        // A settings file written by any pre-What's-New build has no
        // lastSeenAppVersion key; it must decode as "" (never shown) with
        // every other field untouched.
        let json = """
        {
          "archiveEnabled": true,
          "retentionMode": "recent-50",
          "hasCompletedOnboarding": true
        }
        """
        let settings = try JSONDecoder().decode(
            ClipboardSettings.self,
            from: Data(json.utf8)
        )
        #expect(settings.lastSeenAppVersion == "")
        #expect(settings.archiveEnabled == true)
        #expect(settings.retentionMode == .recent50)
        #expect(settings.hasCompletedOnboarding == true)
    }

    @Test
    func testLastSeenAppVersionRoundTrips() throws {
        var settings = ClipboardSettings()
        #expect(settings.lastSeenAppVersion == "")
        settings.lastSeenAppVersion = "0.2.0"

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(settings)
        let encoded = try #require(String(data: data, encoding: .utf8))
        #expect(encoded.contains("\"lastSeenAppVersion\":\"0.2.0\""))

        let decoded = try JSONDecoder().decode(ClipboardSettings.self, from: data)
        #expect(decoded.lastSeenAppVersion == "0.2.0")
        #expect(decoded == settings)
    }

    @Test
    func testLastSeenAppVersionRoundTripsThroughStore() throws {
        // Production save/load path against an isolated /tmp settings file.
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("clipboard-whatsnew-tests-\(UUID().uuidString)")
        defer {
            try? FileManager.default.removeItem(at: directory)
        }
        let store = ClipboardSettingsStore(
            settingsURL: directory.appendingPathComponent("settings.json")
        )
        var settings = ClipboardSettings(hasCompletedOnboarding: true)
        settings.lastSeenAppVersion = "0.2.0"
        try store.save(settings)
        let reloaded = store.load()
        #expect(reloaded.lastSeenAppVersion == "0.2.0")
        #expect(reloaded.hasCompletedOnboarding == true)
    }

    // MARK: - Pure show decision

    @Test(arguments: [
        // (hasCompletedOnboarding, lastSeenVersion, currentVersion, expected)
        // Never during incomplete first-run onboarding.
        (false, "", "0.2.0", false),
        (false, "0.1.0", "0.2.0", false),
        // Once after upgrade — including existing users whose settings file
        // predates the key entirely (empty != "0.2.0").
        (true, "", "0.2.0", true),
        (true, "0.1.0", "0.2.0", true),
        // Not again after the presenter persists the current version.
        (true, "0.2.0", "0.2.0", false),
        // Not when versions are equal (development builds included).
        (true, "development", "development", false),
        // Never for an empty current version (nothing to stamp).
        (true, "", "", false)
    ])
    func testShouldShowTable(
        _ row: (hasCompletedOnboarding: Bool, lastSeen: String, current: String, expected: Bool)
    ) {
        #expect(
            ClipboardWhatsNew.shouldShow(
                hasCompletedOnboarding: row.hasCompletedOnboarding,
                lastSeenVersion: row.lastSeen,
                currentVersion: row.current
            ) == row.expected
        )
    }
}
