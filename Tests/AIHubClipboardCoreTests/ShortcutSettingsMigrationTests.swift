import Foundation
import Testing
@testable import ClipboardArchiveCore

/// Settings migration fixtures for the Slice 2 shortcut keys (expansion
/// contract 4): a settings file from any older build must load without
/// behavior change beyond documented defaults, and unknown future action
/// ids must survive a load/save round-trip.
@Suite("Shortcut Settings Migration")
struct ShortcutSettingsMigrationTests {
    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "clipboard-shortcut-settings-tests-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// A settings.json exactly as the current released build (pre-Slice 2)
    /// writes it: no `shortcuts` key, no `quickPickerDirectPasteEnabled`.
    private func preSliceTwoSettingsJSON() -> String {
        """
        {
          "archiveEnabled" : true,
          "excludedAppNameFragments" : [],
          "excludedBundleIdentifiers" : [
            "com.example.passwords"
          ],
          "hasCompletedOnboarding" : true,
          "historyWindow" : 7,
          "pollIntervalSeconds" : 0.2,
          "recentItemLimit" : 50,
          "retentionMode" : "unlimited"
        }
        """
    }

    @Test
    func testPreSliceTwoSettingsFileLoadsWithDisabledShortcutDefaults() throws {
        let settings = try JSONDecoder().decode(
            ClipboardSettings.self,
            from: Data(preSliceTwoSettingsJSON().utf8)
        )

        #expect(settings.shortcuts.isEmpty)
        #expect(settings.quickPickerShortcut == .quickPickerDefault)
        #expect(settings.quickPickerShortcut.enabled == false)
        #expect(settings.quickPickerDirectPasteEnabled == false)
        // Existing behavior is untouched.
        #expect(settings.archiveEnabled)
        #expect(settings.recentItemLimit == 50)
        #expect(settings.retentionMode == .unlimited)
        #expect(settings.excludedBundleIdentifiers == ["com.example.passwords"])
    }

    @Test
    func testFutureUnknownActionIDLoadsAndRoundTrips() throws {
        let json = """
        {
          "archiveEnabled" : true,
          "hasCompletedOnboarding" : true,
          "quickPickerDirectPasteEnabled" : true,
          "shortcuts" : {
            "quickPicker" : {
              "enabled" : true,
              "keyCode" : 9,
              "modifiers" : ["option", "command"]
            },
            "futureSnippetPalette" : {
              "enabled" : true,
              "keyCode" : 40,
              "modifiers" : ["control", "command"]
            }
          }
        }
        """
        let settings = try JSONDecoder().decode(ClipboardSettings.self, from: Data(json.utf8))

        #expect(settings.shortcuts.count == 2)
        #expect(settings.quickPickerShortcut.enabled)
        #expect(settings.quickPickerShortcut.keyCode == 9)
        #expect(settings.quickPickerDirectPasteEnabled)
        let future = try #require(settings.shortcuts["futureSnippetPalette"])
        #expect(future.keyCode == 40)
        #expect(future.modifiers == ["control", "command"])

        // The unknown action id must survive re-encoding untouched.
        let encoded = try JSONEncoder().encode(settings)
        let decoded = try JSONDecoder().decode(ClipboardSettings.self, from: encoded)
        #expect(decoded.shortcuts["futureSnippetPalette"] == future)
    }

    @Test
    func testShortcutSettingsRoundTripThroughAtomicStore() throws {
        let directory = try temporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: directory)
        }
        let store = ClipboardSettingsStore(
            settingsURL: directory.appendingPathComponent("settings.json")
        )

        var settings = ClipboardSettings(
            archiveEnabled: true,
            hasCompletedOnboarding: true
        )
        settings.quickPickerShortcut = ClipboardShortcutSetting(
            enabled: true,
            keyCode: 49,
            modifiers: ["control", "option"]
        )
        settings.quickPickerDirectPasteEnabled = true

        try store.save(settings)
        let loaded = store.load()

        #expect(loaded == settings)
        #expect(loaded.quickPickerShortcut.enabled)
        #expect(loaded.quickPickerShortcut.keyCode == 49)
        #expect(loaded.quickPickerShortcut.modifiers == ["control", "option"])
        #expect(loaded.quickPickerShortcut.displayString == "⌃⌥Space")
        #expect(loaded.quickPickerDirectPasteEnabled)
    }

    @Test
    func testQuickPickerShortcutAccessorWritesIntoDictionary() {
        var settings = ClipboardSettings()
        #expect(settings.shortcuts.isEmpty)

        var shortcut = settings.quickPickerShortcut
        #expect(shortcut == .quickPickerDefault)
        shortcut.enabled = true
        settings.quickPickerShortcut = shortcut

        #expect(settings.shortcuts[ClipboardShortcutSetting.quickPickerActionID]?.enabled == true)
        #expect(settings.quickPickerShortcut.enabled)
    }
}
