import Foundation
import Testing
@testable import ClipboardArchiveCore

/// Falling back to defaults on an unreadable settings file is not a neutral
/// act: it turns capture OFF, marks onboarding incomplete, and replaces a
/// chosen retention mode with "keep the latest 50" — it can shrink someone's
/// archive. These tests pin the last-known-good copy that prevents it.
@Suite("Settings last-known-good")
struct SettingsLastGoodTests {
    private func makeStore() throws -> (store: ClipboardSettingsStore, base: URL) {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("clipboard-settings-lastgood-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return (ClipboardSettingsStore(settingsURL: base.appendingPathComponent("settings.json")), base)
    }

    private func chosenSettings() -> ClipboardSettings {
        var settings = ClipboardSettings()
        settings.archiveEnabled = true
        settings.retentionMode = .unlimited
        settings.hasCompletedOnboarding = true
        settings.excludedBundleIdentifiers = ["com.example.secrets"]
        return settings
    }

    private func quarantineFiles(_ base: URL) throws -> [String] {
        try FileManager.default.contentsOfDirectory(at: base, includingPropertiesForKeys: nil)
            .map(\.lastPathComponent)
            .filter { $0.contains(".corrupt-") }
            .sorted()
    }

    /// The case that matters: corrupt bytes, a good copy beside them. The
    /// user's own choices come back, the bad file is set aside, and the
    /// reason says the copy was used rather than defaults.
    @Test func corruptSettingsLoadTheLastGoodCopy() throws {
        let (store, base) = try makeStore()
        defer { try? FileManager.default.removeItem(at: base) }
        try store.save(chosenSettings())
        try Data("{ this is not settings".utf8).write(to: store.settingsURL)

        let loaded = store.loadReporting()
        let quarantined = try quarantineFiles(base)
        print("SETTINGS_LASTGOOD archiveEnabled=\(loaded.settings.archiveEnabled) retention=\(loaded.settings.retentionMode.rawValue) onboarded=\(loaded.settings.hasCompletedOnboarding) reason=\(loaded.fallback?.rawValue ?? "none") quarantine=\(quarantined)")
        #expect(loaded.fallback == .lastGoodUsed)
        #expect(loaded.settings == chosenSettings())
        #expect(quarantined.count == 1)
        // `load()` benefits identically — every existing caller is covered.
        #expect(store.load().retentionMode == .unlimited)
    }

    /// No copy to fall back to: defaults, and the reason names the real
    /// failure rather than pretending a copy was used. The unreadable file
    /// STAYS — moving the only file there is would turn a transient read
    /// failure into permanent loss, because the next save writes defaults.
    @Test func corruptSettingsWithoutACopyReturnDefaultsAndKeepTheFile() throws {
        let (store, base) = try makeStore()
        defer { try? FileManager.default.removeItem(at: base) }
        let bytes = Data("{ this is not settings".utf8)
        try bytes.write(to: store.settingsURL)

        let loaded = store.loadReporting()
        let survived = try Data(contentsOf: store.settingsURL)
        print("SETTINGS_NO_BAK reason=\(loaded.fallback?.rawValue ?? "none") retention=\(loaded.settings.retentionMode.rawValue) file_kept=\(survived == bytes) quarantine=\(try quarantineFiles(base))")
        #expect(loaded.fallback == .corrupt)
        #expect(loaded.settings == ClipboardSettings())
        #expect(survived == bytes)
        #expect(try quarantineFiles(base).isEmpty)
    }

    /// A healthy file is read as itself; the copy is never consulted, even
    /// when it disagrees.
    @Test func healthySettingsIgnoreTheCopy() throws {
        let (store, base) = try makeStore()
        defer { try? FileManager.default.removeItem(at: base) }
        try store.save(chosenSettings())
        // A deliberately different copy: if it were read, this would show.
        var stale = ClipboardSettings()
        stale.excludedBundleIdentifiers = ["com.example.stale"]
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(stale).write(to: store.lastGoodURL)

        let loaded = store.loadReporting()
        print("SETTINGS_HEALTHY reason=\(loaded.fallback?.rawValue ?? "none") excluded=\(loaded.settings.excludedBundleIdentifiers)")
        #expect(loaded.fallback == nil)
        #expect(loaded.settings.excludedBundleIdentifiers == ["com.example.secrets"])
        #expect(try quarantineFiles(base).isEmpty)
    }

    /// The copy is written by save, after the real file, and matches it byte
    /// for byte at 0600.
    @Test func saveWritesTheCopyAfterTheMainFile() throws {
        let (store, base) = try makeStore()
        defer { try? FileManager.default.removeItem(at: base) }
        try store.save(chosenSettings())

        let main = try Data(contentsOf: store.settingsURL)
        let copy = try Data(contentsOf: store.lastGoodURL)
        let mode = (try FileManager.default.attributesOfItem(atPath: store.lastGoodURL.path)[.posixPermissions] as? NSNumber)?.intValue
        print("SETTINGS_BAK bytes=\(copy.count) equal=\(main == copy) mode=\(String(mode ?? -1, radix: 8))")
        #expect(main == copy)
        #expect(mode == 0o600)
    }

    /// An existing quarantine is never overwritten: the FIRST failure is the
    /// one worth keeping. A second failure in the same second therefore
    /// leaves its bytes in place rather than replacing the kept copy.
    @Test func quarantineNeverOverwritesAnExistingCopy() throws {
        let (store, base) = try makeStore()
        defer { try? FileManager.default.removeItem(at: base) }
        try store.save(chosenSettings())
        let first = Data("{ first corruption".utf8)
        try first.write(to: store.settingsURL)
        #expect(store.loadReporting().fallback == .lastGoodUsed)
        let afterFirst = try quarantineFiles(base)
        #expect(afterFirst.count == 1)
        let quarantineURL = base.appendingPathComponent(afterFirst[0])
        #expect(try Data(contentsOf: quarantineURL) == first)

        let second = Data("{ second corruption".utf8)
        try second.write(to: store.settingsURL)
        #expect(store.loadReporting().fallback == .lastGoodUsed)
        let afterSecond = try quarantineFiles(base)
        let kept = try Data(contentsOf: quarantineURL)
        let sameSecond = afterSecond == afterFirst
        let stillThere = FileManager.default.fileExists(atPath: store.settingsURL.path)
        print("SETTINGS_QUARANTINE first=\(afterFirst) second=\(afterSecond) kept_is_first=\(kept == first) same_second=\(sameSecond) main_kept=\(stillThere)")
        // Either the clock ticked and the second failure got its own file,
        // or it did not and the second file stayed where it was — never an
        // overwrite of the first.
        #expect(kept == first)
        if sameSecond {
            #expect(stillThere)
            #expect(try Data(contentsOf: store.settingsURL) == second)
        } else {
            #expect(afterSecond.count == 2)
        }
    }
}
