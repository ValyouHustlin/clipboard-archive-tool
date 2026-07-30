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

    public init(mode: String, addedAt: Date = Date()) {
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
        addedAt = try container.decodeIfPresent(Date.self, forKey: .addedAt) ?? .distantPast
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
        richImageMaxBytes: Int = ClipboardSettings.defaultRichImageMaxBytes
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
        return privateModeUntil > Date()
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
        return pauseUntil > Date()
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        excludedBundleIdentifiers = try container.decodeIfPresent([String].self, forKey: .excludedBundleIdentifiers) ?? []
        excludedAppNameFragments = try container.decodeIfPresent([String].self, forKey: .excludedAppNameFragments) ?? []
        pauseUntil = try container.decodeIfPresent(Date.self, forKey: .pauseUntil)
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
        privateModeUntil = try container.decodeIfPresent(Date.self, forKey: .privateModeUntil)
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
    }

    public static func clampRecentItemLimit(_ value: Int) -> Int {
        max(minimumRecentItemLimit, min(maximumRecentItemLimit, value))
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

public struct ClipboardSettingsStore: Sendable {
    public var settingsURL: URL

    public init(settingsURL: URL = ClipboardSettingsStore.defaultSettingsURL()) {
        self.settingsURL = settingsURL
    }

    public func load() -> ClipboardSettings {
        guard let attributes = try? FileManager.default.attributesOfItem(
            atPath: settingsURL.path
        ),
              attributes[.type] as? FileAttributeType == .typeRegular else {
            return ClipboardSettings()
        }
        do {
            try ClipboardPrivateFileSystem.secureFile(settingsURL)
        } catch {
            return ClipboardSettings()
        }
        guard let data = try? Data(contentsOf: settingsURL) else {
            return ClipboardSettings()
        }
        // save() encodes dates as ISO 8601, so load MUST decode them the
        // same way. The plain-decoder fallback keeps hypothetical files with
        // numeric dates loading instead of silently resetting to defaults.
        let isoDecoder = JSONDecoder()
        isoDecoder.dateDecodingStrategy = .iso8601
        if let settings = try? isoDecoder.decode(ClipboardSettings.self, from: data) {
            return settings
        }
        guard let settings = try? JSONDecoder().decode(ClipboardSettings.self, from: data) else {
            return ClipboardSettings()
        }
        return settings
    }

    public func save(_ settings: ClipboardSettings) throws {
        let directory = settingsURL.deletingLastPathComponent()
        try ClipboardPrivateFileSystem.createDirectory(directory, archiveRoot: directory)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(settings)
        try data.write(to: settingsURL, options: [.atomic])
        try ClipboardPrivateFileSystem.secureFile(settingsURL)
    }

    public static func defaultSettingsURL() -> URL {
        ClipboardDefaults.settingsURL()
    }
}
