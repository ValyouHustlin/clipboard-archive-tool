import Foundation
import Testing
@testable import ClipboardArchiveCore

/// An update must carry every choice the user made. The files here are what
/// the public 0.1.2 build saves (seven keys, pretty-printed, sorted, with
/// `pauseUntil` left out when there is no pause), read and then saved again
/// the way today's app does on its first launch after an update.
@Suite("Settings carried over an update")
struct SettingsUpgradeTests {
    private func store(holding document: String) throws -> (store: ClipboardSettingsStore, base: URL) {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("clipboard-settings-upgrade-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let url = base.appendingPathComponent("settings.json")
        try Data(document.utf8).write(to: url)
        return (ClipboardSettingsStore(settingsURL: url), base)
    }

    private static let fullArchiveFrom012 = """
    {
      "archiveEnabled" : true,
      "excludedAppNameFragments" : [
        "private notes"
      ],
      "excludedBundleIdentifiers" : [
        "com.example.bank"
      ],
      "pollIntervalSeconds" : 0.5,
      "recentItemLimit" : 120,
      "retentionMode" : "unlimited"
    }
    """

    private static let captureOffFrom012 = """
    {
      "archiveEnabled" : false,
      "excludedAppNameFragments" : [

      ],
      "excludedBundleIdentifiers" : [

      ],
      "pollIntervalSeconds" : 0.2,
      "recentItemLimit" : 10,
      "retentionMode" : "recent-10"
    }
    """

    private func expectFullArchiveChoices(_ settings: ClipboardSettings) {
        #expect(settings.archiveEnabled)
        #expect(settings.retentionMode == .unlimited)
        #expect(settings.recentItemLimit == 120)
        #expect(settings.pollIntervalSeconds == 0.5)
        #expect(settings.excludedBundleIdentifiers == ["com.example.bank"])
        #expect(settings.excludedAppNameFragments == ["private notes"])
    }

    @Test func every012ChoiceLoadsWithoutFallingBackToDefaults() throws {
        let (store, base) = try store(holding: Self.fullArchiveFrom012)
        defer { try? FileManager.default.removeItem(at: base) }

        let loaded = store.loadReporting()
        #expect(loaded.fallback == nil)
        expectFullArchiveChoices(loaded.settings)
        // Someone who was already using the app is not sent through first-run
        // setup again, which is where capture could be switched off.
        #expect(loaded.settings.hasCompletedOnboarding)
    }

    @Test func theExcludedAppIsStillBlockedAfterTheUpdate() throws {
        let (store, base) = try store(holding: Self.fullArchiveFrom012)
        defer { try? FileManager.default.removeItem(at: base) }

        let filter = ClipboardPrivacyFilter(settings: store.load())
        let fromTheBank = ClipboardCapture(
            content: "ordinary text copied in an excluded app",
            sourceApp: ClipboardSourceApp(name: "Bank", bundleIdentifier: "com.example.bank"),
            pasteboardTypes: ["public.utf8-plain-text"]
        )
        guard case .block = filter.evaluate(fromTheBank) else {
            Issue.record("a capture from an app excluded before the update was allowed after it")
            return
        }
    }

    /// The app saves the settings on its first launch after an update (it
    /// records the version it last ran). That save must keep every choice,
    /// and keep them under the names the older build reads, so going back
    /// to it loses nothing either.
    @Test func savingAfterTheUpdateKeepsEveryChoiceUnderItsOldName() throws {
        let (store, base) = try store(holding: Self.fullArchiveFrom012)
        defer { try? FileManager.default.removeItem(at: base) }

        var settings = store.load()
        settings.lastSeenAppVersion = "0.4.2"
        try store.save(settings)

        let reloaded = store.loadReporting()
        #expect(reloaded.fallback == nil)
        expectFullArchiveChoices(reloaded.settings)

        let saved = try #require(
            JSONSerialization.jsonObject(with: Data(contentsOf: store.settingsURL)) as? [String: Any]
        )
        #expect(saved["archiveEnabled"] as? Bool == true)
        #expect(saved["retentionMode"] as? String == "unlimited")
        #expect(saved["recentItemLimit"] as? Int == 120)
        #expect(saved["pollIntervalSeconds"] as? Double == 0.5)
        #expect(saved["excludedBundleIdentifiers"] as? [String] == ["com.example.bank"])
        #expect(saved["excludedAppNameFragments"] as? [String] == ["private notes"])
    }

    /// The other direction matters as much: an update must never switch
    /// capture ON for someone who had it off, or widen what is kept.
    @Test func captureThatWasOffStaysOffAndKeepsItsLimit() throws {
        let (store, base) = try store(holding: Self.captureOffFrom012)
        defer { try? FileManager.default.removeItem(at: base) }

        var settings = store.loadReporting()
        #expect(settings.fallback == nil)
        #expect(!settings.settings.archiveEnabled)
        #expect(settings.settings.retentionMode == .recent10)
        #expect(settings.settings.recentItemLimit == 10)

        settings.settings.lastSeenAppVersion = "0.4.2"
        try store.save(settings.settings)
        let reloaded = store.load()
        #expect(!reloaded.archiveEnabled)
        #expect(reloaded.retentionMode == .recent10)
        #expect(reloaded.recentItemLimit == 10)
    }
}
