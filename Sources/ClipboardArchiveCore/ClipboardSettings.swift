import Foundation

public enum ClipboardRetentionMode: String, Codable, CaseIterable, Sendable {
    case recent10 = "recent-10"
    case recent50 = "recent-50"
    case unlimited = "unlimited"

    public var displayName: String {
        switch self {
        case .recent10:
            return "Remember 10 Items"
        case .recent50:
            return "Remember 50 Items"
        case .unlimited:
            return "Full Archive"
        }
    }

    public var retainedItemLimit: Int? {
        switch self {
        case .recent10:
            return 10
        case .recent50:
            return 50
        case .unlimited:
            return nil
        }
    }

    public var storesLongTermHistory: Bool {
        self == .unlimited
    }
}

public enum ClipboardHistoryWindow: Int, Codable, CaseIterable, Sendable {
    case oneDay = 1
    case sevenDays = 7
    case fourteenDays = 14
    case thirtyDays = 30

    public var displayName: String {
        switch self {
        case .oneDay:
            return "Last 24 Hours"
        case .sevenDays:
            return "Last 7 Days"
        case .fourteenDays:
            return "Last 14 Days"
        case .thirtyDays:
            return "Last 30 Days"
        }
    }

    public var dayCount: Int {
        rawValue
    }
}

/// One per-app privacy rule (Slice 5). `mode` is a RAW string that
/// round-trips losslessly: known values are `normal`, `store-no-index`, and
/// `block`; any UNKNOWN value written by a newer build evaluates as `block`
/// (fail closed) but re-encodes unchanged so newer settings are never
/// clobbered.
public struct ClipboardAppPrivacyRule: Codable, Equatable, Sendable {
    public static let normalMode = "normal"
    public static let storeNoIndexMode = "store-no-index"
    public static let blockMode = "block"
    public static let knownModes: [String] = [normalMode, storeNoIndexMode, blockMode]

    public var mode: String
    public var addedAt: Date

    public init(mode: String, addedAt: Date = ClipboardRuntime.now) {
        self.mode = mode
        self.addedAt = addedAt
    }

    private enum CodingKeys: String, CodingKey {
        case mode
        case addedAt
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        // A missing mode is indistinguishable from an unknown one and both
        // must fail closed, so default to the empty string (evaluates as
        // block) rather than dropping the record.
        mode = try container.decodeIfPresent(String.self, forKey: .mode) ?? ""
        // A malformed/mixed-format date must not fail this rule's decode:
        // FailableDecodable would then DROP the rule, silently un-blocking
        // the app (fail-open). The timestamp is cosmetic; the mode is not.
        if let date = try? container.decodeIfPresent(Date.self, forKey: .addedAt) {
            addedAt = date
        } else if let string = try? container.decodeIfPresent(String.self, forKey: .addedAt),
                  let parsed = ISO8601DateFormatter().date(from: string) {
            addedAt = parsed
        } else {
            addedAt = .distantPast
        }
    }

    /// Fail-closed evaluation (contract: unknown mode weakens nothing).
    public var evaluatesAsBlock: Bool {
        mode != Self.normalMode && mode != Self.storeNoIndexMode
    }

    public var isStoreNoIndex: Bool {
        mode == Self.storeNoIndexMode
    }

    public var isNormal: Bool {
        mode == Self.normalMode
    }
}

public struct ClipboardSettings: Codable, Equatable, Sendable {
    public static let minimumRecentItemLimit = 5
    public static let maximumRecentItemLimit = 10_000
    public static let currentSettingsVersion = 1
    /// Default cap for stored image payloads (Slice 6, contract 7):
    /// larger images become a visible blocked event instead of a body file.
    public static let defaultRichImageMaxBytes = 10 * 1024 * 1024

    public var excludedBundleIdentifiers: [String]
    public var excludedAppNameFragments: [String]
    public var pauseUntil: Date?
    public var pollIntervalSeconds: TimeInterval
    public var archiveEnabled: Bool
    public var recentItemLimit: Int
    public var historyWindow: ClipboardHistoryWindow
    public var retentionMode: ClipboardRetentionMode
    public var hasCompletedOnboarding: Bool
    /// Global shortcut configuration keyed by action id (expansion
    /// contract 8). Dictionary-keyed so future shortcut actions need no
    /// settings migration; unknown action ids from newer builds load and
    /// round-trip untouched.
    public var shortcuts: [String: ClipboardShortcutSetting]
    /// Opt-in direct paste after a quick picker commit. Requires
    /// Accessibility trust at use time and degrades to copy-back silently.
    public var quickPickerDirectPasteEnabled: Bool
    /// History window "Group duplicates" toggle (Slice 4). Presentation
    /// only; defaults off so older settings files change nothing.
    public var historyGroupDuplicates: Bool
    /// Settings semantic version (contract 4). Missing decodes as 1.
    public var settingsVersion: Int
    /// Per-app privacy rules keyed by LOWERCASED bundle identifier
    /// (Slice 5). Unknown modes evaluate as block but round-trip losslessly.
    public var appPrivacyRules: [String: ClipboardAppPrivacyRule]
    /// Timed private mode: while set and in the future, the capture loop
    /// returns before reading the pasteboard — no stored events and no
    /// blocked-event metadata lines.
    public var privateModeUntil: Date?
    /// Opt-in menu status line describing the most recent blocked event.
    public var showBlockedEventStatus: Bool
    /// Rich-format capture (Slice 6): images, file references, RTF, colors,
    /// and titled links. Default ON per the approved rich-formats design
    /// (lead decision 2026-07-30); turning it off restores text-only capture.
    public var captureRichContent: Bool
    /// Size cap for stored image payloads; larger images are blocked with a
    /// visible `image_exceeds_size_cap` reason (contract 7).
    public var richImageMaxBytes: Int
    /// The app version whose "What's New" window the user has already been
    /// shown. Empty means "never shown" (contract 4: missing key decodes to
    /// the conservative default), so both fresh installs and files written
    /// by older builds naturally qualify for one post-upgrade showing.
    public var lastSeenAppVersion: String

    private enum CodingKeys: String, CodingKey {
        case excludedBundleIdentifiers
        case excludedAppNameFragments
        case pauseUntil
        case pollIntervalSeconds
        case archiveEnabled
        case recentItemLimit
        case historyWindow
        case retentionMode
        case hasCompletedOnboarding
        case shortcuts
        case quickPickerDirectPasteEnabled
        case historyGroupDuplicates
        case settingsVersion
        case appPrivacyRules
        case privateModeUntil
        case showBlockedEventStatus
        case captureRichContent
        case richImageMaxBytes
        case lastSeenAppVersion
    }

    public init(
        excludedBundleIdentifiers: [String] = [],
        excludedAppNameFragments: [String] = [],
        pauseUntil: Date? = nil,
        pollIntervalSeconds: TimeInterval = 0.2,
        archiveEnabled: Bool = false,
        recentItemLimit: Int = 50,
        historyWindow: ClipboardHistoryWindow = .sevenDays,
        retentionMode: ClipboardRetentionMode = .recent50,
        hasCompletedOnboarding: Bool = false,
        shortcuts: [String: ClipboardShortcutSetting] = [:],
        quickPickerDirectPasteEnabled: Bool = false,
        historyGroupDuplicates: Bool = false,
        settingsVersion: Int = ClipboardSettings.currentSettingsVersion,
        appPrivacyRules: [String: ClipboardAppPrivacyRule] = [:],
        privateModeUntil: Date? = nil,
        showBlockedEventStatus: Bool = true,
        captureRichContent: Bool = true,
        richImageMaxBytes: Int = ClipboardSettings.defaultRichImageMaxBytes,
        lastSeenAppVersion: String = ""
    ) {
        self.excludedBundleIdentifiers = excludedBundleIdentifiers
        self.excludedAppNameFragments = excludedAppNameFragments
        self.pauseUntil = pauseUntil
        self.pollIntervalSeconds = pollIntervalSeconds
        self.archiveEnabled = archiveEnabled
        self.recentItemLimit = Self.clampRecentItemLimit(recentItemLimit)
        self.historyWindow = historyWindow
        self.retentionMode = retentionMode
        self.hasCompletedOnboarding = hasCompletedOnboarding
        self.shortcuts = shortcuts
        self.quickPickerDirectPasteEnabled = quickPickerDirectPasteEnabled
        self.historyGroupDuplicates = historyGroupDuplicates
        self.settingsVersion = settingsVersion
        self.appPrivacyRules = Self.normalizedRuleKeys(appPrivacyRules)
        self.privateModeUntil = privateModeUntil
        self.showBlockedEventStatus = showBlockedEventStatus
        self.captureRichContent = captureRichContent
        self.richImageMaxBytes = Self.clampRichImageMaxBytes(richImageMaxBytes)
        self.lastSeenAppVersion = lastSeenAppVersion
    }

    /// Rule keys are canonically lowercased bundle identifiers. When a
    /// hand-edited file carries both casings, the lowercased entry wins so
    /// normalization is deterministic.
    public static func normalizedRuleKeys(
        _ rules: [String: ClipboardAppPrivacyRule]
    ) -> [String: ClipboardAppPrivacyRule] {
        var normalized: [String: ClipboardAppPrivacyRule] = [:]
        for (key, rule) in rules.sorted(by: { $0.key < $1.key }) {
            let lowered = key.lowercased()
            if normalized[lowered] == nil || key == lowered {
                normalized[lowered] = rule
            }
        }
        return normalized
    }

    public var isPrivateModeActive: Bool {
        guard let privateModeUntil else {
            return false
        }
        return privateModeUntil > ClipboardRuntime.now
    }

    /// The quick picker shortcut, falling back to the disabled ⌥⌘V default
    /// when no entry exists (settings written by older builds).
    public var quickPickerShortcut: ClipboardShortcutSetting {
        get {
            shortcuts[ClipboardShortcutSetting.quickPickerActionID]
                ?? .quickPickerDefault
        }
        set {
            shortcuts[ClipboardShortcutSetting.quickPickerActionID] = newValue
        }
    }

    public var isTemporarilyPaused: Bool {
        guard let pauseUntil else {
            return false
        }
        return pauseUntil > ClipboardRuntime.now
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        excludedBundleIdentifiers = try container.decodeIfPresent([String].self, forKey: .excludedBundleIdentifiers) ?? []
        excludedAppNameFragments = try container.decodeIfPresent([String].self, forKey: .excludedAppNameFragments) ?? []
        pauseUntil = Self.flexibleDate(in: container, forKey: .pauseUntil)
        pollIntervalSeconds = try container.decodeIfPresent(TimeInterval.self, forKey: .pollIntervalSeconds) ?? 0.2
        archiveEnabled = try container.decodeIfPresent(Bool.self, forKey: .archiveEnabled) ?? true
        let decodedLimit = try container.decodeIfPresent(Int.self, forKey: .recentItemLimit) ?? 50
        recentItemLimit = Self.clampRecentItemLimit(decodedLimit)
        historyWindow = try container.decodeIfPresent(
            ClipboardHistoryWindow.self,
            forKey: .historyWindow
        ) ?? .sevenDays
        retentionMode = try container.decodeIfPresent(ClipboardRetentionMode.self, forKey: .retentionMode) ?? (archiveEnabled ? .unlimited : .recent50)
        hasCompletedOnboarding = try container.decodeIfPresent(Bool.self, forKey: .hasCompletedOnboarding) ?? true
        // A malformed entry (wrong value type, future schema hiccup) must
        // drop only that entry — never fail the whole settings decode, which
        // would reset capture/retention/exclusions to factory defaults.
        let tolerantShortcuts = try container.decodeIfPresent(
            [String: FailableDecodable<ClipboardShortcutSetting>].self,
            forKey: .shortcuts
        ) ?? [:]
        shortcuts = tolerantShortcuts.compactMapValues(\.value)
        quickPickerDirectPasteEnabled = try container.decodeIfPresent(
            Bool.self,
            forKey: .quickPickerDirectPasteEnabled
        ) ?? false
        historyGroupDuplicates = try container.decodeIfPresent(
            Bool.self,
            forKey: .historyGroupDuplicates
        ) ?? false
        settingsVersion = try container.decodeIfPresent(Int.self, forKey: .settingsVersion) ?? 1
        // One malformed rule entry drops only that entry, never the whole
        // settings decode (which would reset capture/retention/exclusions).
        let tolerantRules = try container.decodeIfPresent(
            [String: FailableDecodable<ClipboardAppPrivacyRule>].self,
            forKey: .appPrivacyRules
        ) ?? [:]
        appPrivacyRules = Self.normalizedRuleKeys(tolerantRules.compactMapValues(\.value))
        privateModeUntil = Self.flexibleDate(in: container, forKey: .privateModeUntil)
        showBlockedEventStatus = try container.decodeIfPresent(
            Bool.self,
            forKey: .showBlockedEventStatus
        ) ?? true
        captureRichContent = try container.decodeIfPresent(
            Bool.self,
            forKey: .captureRichContent
        ) ?? true
        richImageMaxBytes = Self.clampRichImageMaxBytes(
            try container.decodeIfPresent(Int.self, forKey: .richImageMaxBytes)
                ?? Self.defaultRichImageMaxBytes
        )
        lastSeenAppVersion = try container.decodeIfPresent(
            String.self,
            forKey: .lastSeenAppVersion
        ) ?? ""
    }

    public static func clampRecentItemLimit(_ value: Int) -> Int {
        max(minimumRecentItemLimit, min(maximumRecentItemLimit, value))
    }

    /// Decodes a date that may be an ISO 8601 string OR a numeric timestamp,
    /// regardless of the decoder's date strategy. A settings file with mixed
    /// date encodings (hand edit, partial write, format bug) must degrade to
    /// dropping the one odd date — NEVER to failing the whole decode, which
    /// the store would answer with a factory reset that silently un-blocks
    /// the user's privacy rules.
    private static func flexibleDate(
        in container: KeyedDecodingContainer<CodingKeys>,
        forKey key: CodingKeys
    ) -> Date? {
        if let date = try? container.decodeIfPresent(Date.self, forKey: key) {
            return date
        }
        if let string = try? container.decodeIfPresent(String.self, forKey: key) {
            return ISO8601DateFormatter().date(from: string)
        }
        if let seconds = try? container.decodeIfPresent(Double.self, forKey: key) {
            return Date(timeIntervalSinceReferenceDate: seconds)
        }
        return nil
    }

    /// Keeps a hand-edited cap sane: at least 64 KiB so screenshots do not
    /// silently vanish, at most 512 MiB so a typo cannot disable the cap's
    /// memory protection entirely.
    public static func clampRichImageMaxBytes(_ value: Int) -> Int {
        max(64 * 1024, min(512 * 1024 * 1024, value))
    }
}

/// Wraps a decodable value so a malformed instance decodes to nil instead of
/// failing the containing structure's decode.
struct FailableDecodable<Wrapped: Decodable>: Decodable {
    let value: Wrapped?

    init(from decoder: Decoder) throws {
        value = try? Wrapped(from: decoder)
    }
}

/// Why a settings read fell back to defaults. It matters operationally
/// because defaults are NOT the user's choices: a corrupt file silently
/// replaces an "unlimited" retention setting with "keep the latest 50".
public enum ClipboardSettingsFallbackReason: String, Sendable, Equatable {
    /// No regular settings file at the resolved path.
    case missing
    /// The file exists but its permissions could not be tightened.
    case insecure
    /// The file exists and could not be read.
    case unreadable
    /// The bytes are not settings this build can decode.
    case corrupt
    /// The main file could not be read or decoded and the last known-good
    /// copy was loaded instead. NOT a defaults substitution: the user's own
    /// choices — capture on, retention mode — survived.
    case lastGoodUsed
}

public struct ClipboardSettingsStore: Sendable {
    public var settingsURL: URL

    public init(settingsURL: URL = ClipboardSettingsStore.defaultSettingsURL()) {
        self.settingsURL = settingsURL
    }

    public func load() -> ClipboardSettings {
        loadReporting().settings
    }

    /// The same read, plus WHY defaults were substituted when they were.
    /// `load()` stays the shape every existing caller uses; a surface that
    /// can report the fallback calls this one.
    public func loadReporting(readOnly: Bool = false) -> (settings: ClipboardSettings, fallback: ClipboardSettingsFallbackReason?) {
        guard let attributes = try? FileManager.default.attributesOfItem(
            atPath: settingsURL.path
        ),
              attributes[.type] as? FileAttributeType == .typeRegular else {
            // No main file: a first run (no copy either, so defaults), or a
            // file that was quarantined or lost mid-replace — in which case
            // the copy is still the user's own settings.
            return recoverFromLastGood(reasonIfNoCopy: .missing, quarantining: false)
        }
        do {
            if !readOnly { try ClipboardPrivateFileSystem.secureFile(settingsURL) }
        } catch {
            // The file is there but could not be tightened; reading it is
            // not safe, and defaults are the wrong answer here too.
            return recoverFromLastGood(reasonIfNoCopy: .insecure, quarantining: false)
        }
        guard let data = try? Data(contentsOf: settingsURL) else {
            return recoverFromLastGood(reasonIfNoCopy: .unreadable, quarantining: !readOnly)
        }
        guard validDocument(data, compareLastGood: true) else {
            return recoverFromLastGood(reasonIfNoCopy: .corrupt, quarantining: !readOnly)
        }
        // save() encodes dates as ISO 8601, so load MUST decode them the
        // same way. The plain-decoder fallback keeps hypothetical files with
        // numeric dates loading instead of silently resetting to defaults.
        let isoDecoder = JSONDecoder()
        isoDecoder.dateDecodingStrategy = .iso8601
        if let settings = try? isoDecoder.decode(ClipboardSettings.self, from: data) {
            return (settings, nil)
        }
        guard let settings = try? JSONDecoder().decode(ClipboardSettings.self, from: data) else {
            return recoverFromLastGood(reasonIfNoCopy: .corrupt, quarantining: !readOnly)
        }
        return (settings, nil)
    }

    /// Legacy documents may omit newer fields. A document must identify its
    /// capture choice; if a saved copy exists, losing any of its policy keys
    /// is truncation, not a migration. Range errors are reported as fallback.
    private func validDocument(_ data: Data, compareLastGood: Bool) -> Bool {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              object["archiveEnabled"] is NSNumber else { return false }
        if let version = object["settingsVersion"] as? Int,
           version < 1 || version > ClipboardSettings.currentSettingsVersion { return false }
        if let poll = object["pollIntervalSeconds"] as? Double,
           !poll.isFinite || poll < 0.05 || poll > 60 { return false }
        if let limit = object["recentItemLimit"] as? Int,
           limit != ClipboardSettings.clampRecentItemLimit(limit) { return false }
        if let cap = object["richImageMaxBytes"] as? Int,
           cap != ClipboardSettings.clampRichImageMaxBytes(cap) { return false }
        if compareLastGood, let backup = try? Data(contentsOf: lastGoodURL),
           let previous = try? JSONSerialization.jsonObject(with: backup) as? [String: Any] {
            let policyKeys = ["archiveEnabled", "retentionMode", "excludedBundleIdentifiers",
                "excludedAppNameFragments", "appPrivacyRules", "pauseUntil", "privateModeUntil",
                "hasCompletedOnboarding", "captureRichContent", "recentItemLimit", "richImageMaxBytes"]
            // Optional dates can be intentionally removed to resume capture.
            for key in policyKeys where key != "pauseUntil" && key != "privateModeUntil" {
                if previous[key] != nil && object[key] == nil { return false }
            }
        }
        return true
    }

    /// The last-known-good copy, written beside the settings on every
    /// successful save.
    public var lastGoodURL: URL {
        URL(fileURLWithPath: settingsURL.path + ".bak")
    }

    /// Defaults are the WRONG answer to an unreadable settings file: they
    /// turn capture off, mark onboarding incomplete, and replace a chosen
    /// retention mode with "keep the latest 50" — a silent, data-affecting
    /// downgrade of someone's own archive. So the bad bytes are set aside
    /// for inspection and the last good copy is loaded instead; defaults are
    /// used only when there has never been a good copy.
    private func recoverFromLastGood(
        reasonIfNoCopy: ClipboardSettingsFallbackReason,
        quarantining: Bool = true
    ) -> (settings: ClipboardSettings, fallback: ClipboardSettingsFallbackReason?) {
        // The copy is decoded BEFORE anything is moved. Setting a file aside
        // when there is nothing to fall back to would turn a transient read
        // failure into permanent data loss: the next save would write
        // defaults over the only settings that ever existed.
        let isoDecoder = JSONDecoder()
        isoDecoder.dateDecodingStrategy = .iso8601
        guard let data = try? Data(contentsOf: lastGoodURL),
              validDocument(data, compareLastGood: false),
              let settings = (try? isoDecoder.decode(ClipboardSettings.self, from: data))
                ?? (try? JSONDecoder().decode(ClipboardSettings.self, from: data)) else {
            // There is nothing to restore FROM, but the bad bytes are still the
            // only record of what was configured, and `save()` overwrites
            // settings.json unconditionally — so the user opening Settings to
            // flip one checkbox is what destroys them. Declining to MOVE the
            // file here was right (a move plus a defaults save IS the permanent
            // loss the comment above warns about); a COPY has neither problem,
            // and it is the only way the "set aside for inspection" promise is
            // kept in the one case where inspection is the only recourse left.
            if quarantining { preserveUnreadableFile() }
            return (ClipboardSettings(), reasonIfNoCopy)
        }
        if quarantining {
            quarantineUnreadableFile()
        }
        return (settings, .lastGoodUsed)
    }

    /// Moves the unreadable file aside as `settings.json.corrupt-<utc>` so a
    /// person can look at what happened. An existing quarantine is NEVER
    /// overwritten — the first failure is the interesting one — and a
    /// quarantine that cannot be written is not worth failing a load over.
    private func quarantineUnreadableFile() {
        guard let destination = freeQuarantineURL() else { return }
        try? FileManager.default.moveItem(at: settingsURL, to: destination)
        try? ClipboardPrivateFileSystem.secureFile(destination)
    }

    /// Copies the unreadable file aside and LEAVES THE ORIGINAL IN PLACE, for
    /// the case where there is no last-good copy to fall back on. Moving there
    /// would be data loss; copying is a rescue. Best effort throughout: a
    /// rescue that cannot be written must not fail the load it is rescuing.
    private func preserveUnreadableFile() {
        guard let destination = freeQuarantineURL() else { return }
        try? FileManager.default.copyItem(at: settingsURL, to: destination)
        try? ClipboardPrivateFileSystem.secureFile(destination)
    }

    /// `settings.json.corrupt-<utc>`, or nil when there is nothing to set aside
    /// or a quarantine from this second already exists. An existing quarantine
    /// is NEVER overwritten — the first failure is the interesting one.
    private func freeQuarantineURL() -> URL? {
        guard FileManager.default.fileExists(atPath: settingsURL.path) else { return nil }
        let stamp = Self.quarantineFormatter.string(from: ClipboardRuntime.now)
        let destination = URL(fileURLWithPath: settingsURL.path + ".corrupt-" + stamp)
        guard !FileManager.default.fileExists(atPath: destination.path) else { return nil }
        return destination
    }

    private static let quarantineFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        return formatter
    }()

    public func save(_ settings: ClipboardSettings) throws {
        let directory = settingsURL.deletingLastPathComponent()
        try ClipboardPrivateFileSystem.createDirectory(directory, archiveRoot: directory)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(settings)
        try data.writeClipboardAtomically(to: settingsURL)
        try ClipboardPrivateFileSystem.secureFile(settingsURL)
        // The last-known-good copy, written only AFTER the real file landed,
        // so the copy can never be newer than the settings it backs. Best
        // effort: a copy that cannot be written must not fail a save the
        // user just made.
        if (try? data.writeClipboardAtomically(to: lastGoodURL)) != nil {
            try? ClipboardPrivateFileSystem.secureFile(lastGoodURL)
        }
    }

    public static func defaultSettingsURL() -> URL {
        ClipboardDefaults.settingsURL()
    }
}
