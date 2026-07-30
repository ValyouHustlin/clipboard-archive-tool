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

public struct ClipboardSettings: Codable, Equatable, Sendable {
    public static let minimumRecentItemLimit = 5
    public static let maximumRecentItemLimit = 10_000

    public var excludedBundleIdentifiers: [String]
    public var excludedAppNameFragments: [String]
    public var pauseUntil: Date?
    public var pollIntervalSeconds: TimeInterval
    public var archiveEnabled: Bool
    public var recentItemLimit: Int
    public var historyWindow: ClipboardHistoryWindow
    public var retentionMode: ClipboardRetentionMode
    public var hasCompletedOnboarding: Bool

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
        hasCompletedOnboarding: Bool = false
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
    }

    public static func clampRecentItemLimit(_ value: Int) -> Int {
        max(minimumRecentItemLimit, min(maximumRecentItemLimit, value))
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
        guard let data = try? Data(contentsOf: settingsURL),
              let settings = try? JSONDecoder().decode(ClipboardSettings.self, from: data) else {
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
