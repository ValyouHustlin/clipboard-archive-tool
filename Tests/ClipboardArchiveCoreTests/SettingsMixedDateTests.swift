import Foundation
import Testing
@testable import ClipboardArchiveCore

@Suite("Settings Mixed Date Tolerance")
struct SettingsMixedDateTests {
    @Test
    func testMixedDateEncodingsNeverResetSettings() throws {
        // One ISO 8601 date and one epoch-number date in the same file:
        // previously failed BOTH whole-file decode attempts and reset every
        // setting (including privacy rules) to factory defaults.
        let json = """
        {
          "archiveEnabled": true,
          "retentionMode": "unlimited",
          "excludedBundleIdentifiers": ["com.example.vault"],
          "appPrivacyRules": {
            "com.example.bank": { "mode": "block", "addedAt": "2026-07-30T17:00:00Z" }
          },
          "pauseUntil": 775000000.0,
          "privateModeUntil": "2026-07-30T21:00:00Z"
        }
        """
        let store = ClipboardSettingsStore(
            settingsURL: FileManager.default.temporaryDirectory
                .appendingPathComponent("mixed-date-\(UUID().uuidString)")
                .appendingPathComponent("settings.json")
        )
        try FileManager.default.createDirectory(
            at: store.settingsURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data(json.utf8).write(to: store.settingsURL)
        try ClipboardPrivateFileSystem.secureFile(store.settingsURL)

        let settings = store.load()
        #expect(settings.archiveEnabled == true)
        #expect(settings.retentionMode == .unlimited)
        #expect(settings.excludedBundleIdentifiers == ["com.example.vault"])
        #expect(settings.appPrivacyRules["com.example.bank"]?.mode == "block")
        #expect(settings.privateModeUntil != nil)
        #expect(settings.pauseUntil != nil)
    }

    @Test
    func testRuleWithNumericDateSurvivesISODecoderWithoutDroppingBlock() throws {
        // A block rule whose addedAt is a raw number must keep BLOCKING even
        // when the ISO-first decoder cannot parse that timestamp.
        let json = """
        {
          "archiveEnabled": true,
          "appPrivacyRules": {
            "com.example.bank": { "mode": "block", "addedAt": 775000000.0 }
          }
        }
        """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let settings = try decoder.decode(ClipboardSettings.self, from: Data(json.utf8))
        let rule = try #require(settings.appPrivacyRules["com.example.bank"])
        #expect(rule.mode == "block")
    }
}
