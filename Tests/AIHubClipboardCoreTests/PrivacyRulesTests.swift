import Foundation
import Testing
@testable import ClipboardArchiveCore

/// Slice 5 per-app privacy rules: per-mode allowed/blocked/false-positive/
/// non-retention fixtures, filter precedence, unknown-mode fail-closed
/// round-trip, and the store-no-index legacy downgrade write. Synthetic
/// fixtures under temp roots only (contract 10).
@Suite("Privacy Rules")
struct PrivacyRulesTests {
    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("clipboard-privacy-rules-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func capture(
        content: String = "ordinary fixture text",
        bundleID: String? = "com.example.crm",
        appName: String = "Example CRM",
        pasteboardTypes: [String] = ["public.utf8-plain-text"]
    ) -> ClipboardCapture {
        ClipboardCapture(
            content: content,
            sourceApp: ClipboardSourceApp(name: appName, bundleIdentifier: bundleID),
            pasteboardTypes: pasteboardTypes
        )
    }

    private func filter(
        rules: [String: ClipboardAppPrivacyRule] = [:],
        legacyBundles: [String] = [],
        legacyFragments: [String] = []
    ) -> ClipboardPrivacyFilter {
        ClipboardPrivacyFilter(settings: ClipboardSettings(
            excludedBundleIdentifiers: legacyBundles,
            excludedAppNameFragments: legacyFragments,
            appPrivacyRules: rules
        ))
    }

    // MARK: - Per-mode fixtures

    @Test func testNormalRuleAllowsOrdinaryContent() throws {
        let decision = filter(
            rules: ["com.example.crm": ClipboardAppPrivacyRule(mode: "normal")]
        ).evaluate(capture())
        #expect(decision == .allow(sensitivityFlags: []))
    }

    @Test func testBlockRuleBlocksWithAppRuleReasonAndStoresNoContent() throws {
        let archiveRoot = try temporaryDirectory()
        let ingestor = ClipboardIngestor(
            filter: filter(rules: ["com.example.crm": ClipboardAppPrivacyRule(mode: "block")]),
            archiveWriter: ClipboardArchiveWriter(archiveRoot: archiveRoot)
        )
        let secret = "totally-private-fixture-body"
        let result = try ingestor.ingest(capture(content: secret))
        guard case let .blocked(reason) = result else {
            Issue.record("expected block decision")
            return
        }
        #expect(reason == "app_rule_block:com.example.crm")

        // Non-retention byte-compare: the blocked content never appears
        // anywhere under the archive root.
        let files = FileManager.default.enumerator(at: archiveRoot, includingPropertiesForKeys: nil)?
            .compactMap { $0 as? URL } ?? []
        for url in files where (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true {
            let text = (try? String(contentsOf: url)) ?? ""
            #expect(!text.contains(secret))
        }
        // The audit line exists with the machine reason.
        let allText = try files
            .filter { (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true }
            .map { try String(contentsOf: $0) }
            .joined()
        #expect(allText.contains("app_rule_block:com.example.crm"))
    }

    @Test func testStoreNoIndexStoresRestrictedAndSkipsIndex() throws {
        let archiveRoot = try temporaryDirectory()
        let indexURL = try temporaryDirectory().appendingPathComponent("index.sqlite")
        let index = ClipboardDerivedIndex(archiveRoot: archiveRoot, indexURL: indexURL)
        let ingestor = ClipboardIngestor(
            filter: filter(rules: ["com.example.crm": ClipboardAppPrivacyRule(mode: "store-no-index")]),
            archiveWriter: ClipboardArchiveWriter(archiveRoot: archiveRoot),
            derivedIndex: index
        )
        let result = try ingestor.ingest(capture(content: "store-no-index fixture body token"))
        guard case let .stored(event, indexUpdate) = result else {
            Issue.record("expected stored decision")
            return
        }
        #expect(event.privacyLabel == .restricted)
        #expect(event.sensitivityFlags.contains("app-rule-no-index"))
        #expect(indexUpdate == .excluded)
        // Visible to the reader…
        let recent = try ClipboardArchiveReader(archiveRoot: archiveRoot)
            .recentItems(since: .distantPast, limit: 5)
        #expect(recent.map(\.id) == [event.id])
        // …but never searchable.
        #expect(try index.occurrenceIDs(contentHash: event.contentHash).isEmpty)
        #expect(try ClipboardArchiveSearcher(archiveRoot: archiveRoot)
            .search(ClipboardSearchOptions(query: "store-no-index fixture body token")).isEmpty)
    }

    @Test func testFalsePositiveOrdinaryAppStaysUnaffectedByRules() throws {
        let decision = filter(
            rules: ["com.example.crm": ClipboardAppPrivacyRule(mode: "block")]
        ).evaluate(capture(bundleID: "com.example.other", appName: "Other App"))
        #expect(decision == .allow(sensitivityFlags: []))
    }

    // MARK: - Precedence

    @Test func testPasteboardTypeDenylistBeatsEveryRule() throws {
        let decision = filter(
            rules: ["com.example.crm": ClipboardAppPrivacyRule(mode: "normal")]
        ).evaluate(capture(pasteboardTypes: ["org.nspasteboard.ConcealedType"]))
        guard case let .block(reason) = decision else {
            Issue.record("concealed type must block")
            return
        }
        #expect(reason.hasPrefix("pasteboard_type_denylist:"))
    }

    @Test func testNormalRuleCannotOverrideBuiltInPasswordManagers() throws {
        let decision = filter(
            rules: ["com.1password.1password": ClipboardAppPrivacyRule(mode: "normal")]
        ).evaluate(capture(bundleID: "com.1password.1password", appName: "1Password"))
        guard case let .block(reason) = decision else {
            Issue.record("built-in password manager must stay blocked")
            return
        }
        #expect(reason.hasPrefix("source_app_denylist:"))
    }

    @Test func testExplicitRuleBeatsLegacyExclusionList() throws {
        // Legacy list says block; explicit rule says normal → allowed.
        let decision = filter(
            rules: ["com.example.crm": ClipboardAppPrivacyRule(mode: "normal")],
            legacyBundles: ["com.example.crm"]
        ).evaluate(capture())
        #expect(decision == .allow(sensitivityFlags: []))
    }

    @Test func testLegacyListsApplyWhenNoExplicitRuleExists() throws {
        let byBundle = filter(legacyBundles: ["com.example.crm"]).evaluate(capture())
        guard case .block = byBundle else {
            Issue.record("legacy bundle exclusion must block without a rule")
            return
        }
        let byName = filter(legacyFragments: ["example crm"]).evaluate(capture(bundleID: nil))
        guard case .block = byName else {
            Issue.record("legacy name exclusion must block without a rule")
            return
        }
    }

    @Test func testSecretDetectorRunsEvenForStoreNoIndexApps() throws {
        let decision = filter(
            rules: ["com.example.crm": ClipboardAppPrivacyRule(mode: "store-no-index")]
        ).evaluate(capture(content: "GITHUB_TOKEN=" + "ghp_" + "abcdefghijklmnopqrstuvwxyz123456789"))
        guard case let .block(reason) = decision else {
            Issue.record("secret detector must still block store-no-index apps")
            return
        }
        #expect(reason.hasPrefix("secret_detector:"))
    }

    // MARK: - Unknown mode fail-closed + lossless round-trip

    @Test func testUnknownModeEvaluatesAsBlockButRoundTripsLosslessly() throws {
        let json = """
        {
          "appPrivacyRules": {
            "com.example.future": { "mode": "quantum-vault", "addedAt": "2027-01-01T00:00:00Z" }
          }
        }
        """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let settings = try decoder.decode(ClipboardSettings.self, from: Data(json.utf8))
        let rule = try #require(settings.appPrivacyRules["com.example.future"])
        #expect(rule.mode == "quantum-vault")
        #expect(rule.evaluatesAsBlock)

        let decision = ClipboardPrivacyFilter(settings: settings)
            .evaluate(capture(bundleID: "com.example.future", appName: "Future App"))
        guard case let .block(reason) = decision else {
            Issue.record("unknown rule mode must fail closed")
            return
        }
        #expect(reason == "app_rule_block:com.example.future")

        // Lossless re-encode: the unknown mode string survives untouched.
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        let reencoded = String(data: try encoder.encode(settings), encoding: .utf8) ?? ""
        #expect(reencoded.contains("\"mode\":\"quantum-vault\""))
    }

    @Test func testMalformedRuleEntryDropsOnlyThatEntry() throws {
        let json = """
        {
          "recentItemLimit": 77,
          "appPrivacyRules": {
            "com.example.good": { "mode": "normal", "addedAt": "2027-01-01T00:00:00Z" },
            "com.example.bad": "not-a-rule-object"
          }
        }
        """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let settings = try decoder.decode(ClipboardSettings.self, from: Data(json.utf8))
        #expect(settings.recentItemLimit == 77)
        #expect(settings.appPrivacyRules.count == 1)
        #expect(settings.appPrivacyRules["com.example.good"]?.isNormal == true)
    }

    @Test func testRuleKeysNormalizeToLowercase() throws {
        let settings = ClipboardSettings(
            appPrivacyRules: ["COM.Example.CRM": ClipboardAppPrivacyRule(mode: "block")]
        )
        #expect(settings.appPrivacyRules["com.example.crm"] != nil)
        guard case .block = ClipboardPrivacyFilter(settings: settings)
            .evaluate(capture(bundleID: "Com.Example.Crm")) else {
            Issue.record("mixed-case bundle must match the lowercased rule key")
            return
        }
    }

    // MARK: - Settings migration / persistence

    @Test func testOlderSettingsFilesLoadWithSlice5Defaults() throws {
        let json = """
        {
          "excludedBundleIdentifiers": ["com.example.legacy"],
          "recentItemLimit": 50
        }
        """
        let settings = try JSONDecoder().decode(ClipboardSettings.self, from: Data(json.utf8))
        #expect(settings.settingsVersion == 1)
        #expect(settings.appPrivacyRules.isEmpty)
        #expect(settings.privateModeUntil == nil)
        #expect(settings.showBlockedEventStatus)
    }

    @Test func testSettingsStoreRoundTripsRulesAndPersistedDates() throws {
        let root = try temporaryDirectory()
        let store = ClipboardSettingsStore(settingsURL: root.appendingPathComponent("settings.json"))
        var settings = ClipboardSettings()
        settings.appPrivacyRules = [
            "com.example.crm": ClipboardAppPrivacyRule(
                mode: "store-no-index",
                addedAt: Date(timeIntervalSince1970: 1_800_000_000)
            )
        ]
        settings.pauseUntil = Date(timeIntervalSince1970: 1_800_000_100)
        settings.privateModeUntil = Date(timeIntervalSince1970: 1_800_000_200)
        try store.save(settings)

        let loaded = store.load()
        #expect(loaded.appPrivacyRules["com.example.crm"]?.isStoreNoIndex == true)
        // Persisted ISO 8601 dates load back exactly (settings-store decode
        // fix shipped with this slice: dates in the file previously reset
        // the whole settings decode).
        #expect(loaded.pauseUntil == Date(timeIntervalSince1970: 1_800_000_100))
        #expect(loaded.privateModeUntil == Date(timeIntervalSince1970: 1_800_000_200))
    }

    /// Downgrade fail-closed contract: a store-no-index save ALSO keeps the
    /// bundle in the legacy `excludedBundleIdentifiers` list so an OLDER
    /// build (which only knows the legacy list) blocks outright — stricter,
    /// never looser. This test pins the semantic the Settings UI enforces.
    @Test func testStoreNoIndexKeepsLegacyExclusionForOlderBuilds() throws {
        var settings = ClipboardSettings(excludedBundleIdentifiers: ["com.example.crm"])
        settings.appPrivacyRules = ["com.example.crm": ClipboardAppPrivacyRule(mode: "store-no-index")]

        // A build WITHOUT rule support (legacy list only) still blocks.
        var legacyView = settings
        legacyView.appPrivacyRules = [:]
        guard case .block = ClipboardPrivacyFilter(settings: legacyView).evaluate(capture()) else {
            Issue.record("older builds must still block via the legacy list")
            return
        }

        // THIS build stores-no-index (explicit rule beats legacy list).
        guard case .allowStoreNoIndex = ClipboardPrivacyFilter(settings: settings).evaluate(capture()) else {
            Issue.record("current build must store-no-index")
            return
        }
    }
}
