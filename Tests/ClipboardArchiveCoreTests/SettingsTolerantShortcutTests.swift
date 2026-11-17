import Foundation
import Testing
@testable import ClipboardArchiveCore

@Suite("Settings Tolerant Shortcut Decode")
struct SettingsTolerantShortcutTests {
    @Test
    func testMalformedShortcutEntryDropsOnlyThatEntry() throws {
        let json = """
        {
          "archiveEnabled": true,
          "retentionMode": "unlimited",
          "excludedBundleIdentifiers": ["com.example.vault"],
          "shortcuts": {
            "quickPicker": { "enabled": true, "keyCode": 9, "modifiers": ["option", "command"] },
            "brokenAction": { "enabled": true, "keyCode": "not-a-number", "modifiers": ["command"] }
          }
        }
        """
        let settings = try JSONDecoder().decode(
            ClipboardSettings.self,
            from: Data(json.utf8)
        )
        #expect(settings.archiveEnabled == true)
        #expect(settings.retentionMode == .unlimited)
        #expect(settings.excludedBundleIdentifiers == ["com.example.vault"])
        #expect(settings.shortcuts["brokenAction"] == nil)
        let quickPicker = try #require(settings.shortcuts["quickPicker"])
        #expect(quickPicker.enabled == true)
        #expect(quickPicker.keyCode == 9)
    }

    @Test
    func testEntirelyMalformedShortcutsValueStillFailsClosed() throws {
        // A shortcuts value of the wrong container type is a top-level type
        // mismatch; the decode falls back to defaults via the store's
        // existing capture-off fallback rather than crashing.
        let json = """
        { "archiveEnabled": true, "shortcuts": "corrupt" }
        """
        let decoded = try? JSONDecoder().decode(
            ClipboardSettings.self,
            from: Data(json.utf8)
        )
        #expect(decoded == nil)
    }
}
