import Foundation

/// Tolerant content type: known values decode to their named case, unknown
/// raw values decode losslessly to `.other(rawValue)` and re-encode as the
/// original string. This keeps older readers able to decode newer archives.
public enum ClipboardContentType: Codable, Equatable, Hashable, Sendable {
    case text
    case url
    case code
    case blocked
    case other(String)

    public init(rawValue: String) {
        switch rawValue {
        case "text":
            self = .text
        case "url":
            self = .url
        case "code":
            self = .code
        case "blocked":
            self = .blocked
        default:
            self = .other(rawValue)
        }
    }

    public var rawValue: String {
        switch self {
        case .text:
            return "text"
        case .url:
            return "url"
        case .code:
            return "code"
        case .blocked:
            return "blocked"
        case let .other(raw):
            return raw
        }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        self.init(rawValue: try container.decode(String.self))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

public enum PrivacyLabel: String, Codable, Sendable {
    case publicData = "public"
    case privateLocal = "private-local"
    case restricted
    case doNotIndex = "do-not-index"
}

public enum AllowedUse: String, Codable, Sendable {
    case localSearch = "local-search"
    case localAnalysis = "local-analysis"
    case archiveOnly = "archive-only"
    case doNotIndex = "do-not-index"
}

public struct ClipboardSourceApp: Codable, Equatable, Sendable {
    public var name: String
    public var bundleIdentifier: String?

    public init(name: String, bundleIdentifier: String? = nil) {
        self.name = name
        self.bundleIdentifier = bundleIdentifier
    }
}

public struct ClipboardCapture: Equatable, Sendable {
    public var capturedAt: Date
    public var content: String
    public var sourceApp: ClipboardSourceApp
    public var pasteboardTypes: [String]

    public init(
        capturedAt: Date = Date(),
        content: String,
        sourceApp: ClipboardSourceApp,
        pasteboardTypes: [String] = []
    ) {
        self.capturedAt = capturedAt
        self.content = content
        self.sourceApp = sourceApp
        self.pasteboardTypes = pasteboardTypes
    }
}

public struct StoredClipboardEvent: Codable, Equatable, Sendable {
    /// Bump only for semantic changes to the event schema. Fields added after
    /// version 1 must decode with `decodeIfPresent` and a safe default; no new
    /// required fields, ever, within the NDJSON format (expansion contract 1).
    public static let currentSchemaVersion = 1

    public var schemaVersion: Int
    public var id: String
    public var capturedAt: Date
    public var contentType: ClipboardContentType
    public var contentHash: String
    public var contentPreview: String
    public var contentInline: String?
    public var rawContentPath: String?
    public var sourceApp: ClipboardSourceApp
    public var pasteboardTypes: [String]
    public var byteCount: Int
    public var characterCount: Int
    public var lineCount: Int
    public var privacyLabel: PrivacyLabel
    public var allowedUse: [AllowedUse]
    public var sensitivityFlags: [String]
    public var uiVisibleUntil: Date

    public init(
        id: String,
        capturedAt: Date,
        contentType: ClipboardContentType,
        contentHash: String,
        contentPreview: String,
        contentInline: String?,
        rawContentPath: String?,
        sourceApp: ClipboardSourceApp,
        pasteboardTypes: [String],
        byteCount: Int,
        characterCount: Int,
        lineCount: Int,
        privacyLabel: PrivacyLabel,
        allowedUse: [AllowedUse],
        sensitivityFlags: [String],
        uiVisibleUntil: Date,
        schemaVersion: Int = StoredClipboardEvent.currentSchemaVersion
    ) {
        self.schemaVersion = schemaVersion
        self.id = id
        self.capturedAt = capturedAt
        self.contentType = contentType
        self.contentHash = contentHash
        self.contentPreview = contentPreview
        self.contentInline = contentInline
        self.rawContentPath = rawContentPath
        self.sourceApp = sourceApp
        self.pasteboardTypes = pasteboardTypes
        self.byteCount = byteCount
        self.characterCount = characterCount
        self.lineCount = lineCount
        self.privacyLabel = privacyLabel
        self.allowedUse = allowedUse
        self.sensitivityFlags = sensitivityFlags
        self.uiVisibleUntil = uiVisibleUntil
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case id
        case capturedAt
        case contentType
        case contentHash
        case contentPreview
        case contentInline
        case rawContentPath
        case sourceApp
        case pasteboardTypes
        case byteCount
        case characterCount
        case lineCount
        case privacyLabel
        case allowedUse
        case sensitivityFlags
        case uiVisibleUntil
    }

    /// Tolerant decoder (expansion contract 1). Every archive line written
    /// before schema versioning existed is version 1 by definition, so a
    /// missing `schemaVersion` decodes as 1. Fields added after version 1
    /// must use `decodeIfPresent` with a safe default.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
        id = try container.decode(String.self, forKey: .id)
        capturedAt = try container.decode(Date.self, forKey: .capturedAt)
        contentType = try container.decode(ClipboardContentType.self, forKey: .contentType)
        contentHash = try container.decode(String.self, forKey: .contentHash)
        contentPreview = try container.decode(String.self, forKey: .contentPreview)
        contentInline = try container.decodeIfPresent(String.self, forKey: .contentInline)
        rawContentPath = try container.decodeIfPresent(String.self, forKey: .rawContentPath)
        sourceApp = try container.decode(ClipboardSourceApp.self, forKey: .sourceApp)
        pasteboardTypes = try container.decode([String].self, forKey: .pasteboardTypes)
        byteCount = try container.decode(Int.self, forKey: .byteCount)
        characterCount = try container.decode(Int.self, forKey: .characterCount)
        lineCount = try container.decode(Int.self, forKey: .lineCount)
        privacyLabel = try container.decode(PrivacyLabel.self, forKey: .privacyLabel)
        allowedUse = try container.decode([AllowedUse].self, forKey: .allowedUse)
        sensitivityFlags = try container.decode([String].self, forKey: .sensitivityFlags)
        uiVisibleUntil = try container.decode(Date.self, forKey: .uiVisibleUntil)
    }
}

public struct BlockedClipboardEvent: Codable, Equatable, Sendable {
    public var capturedAt: Date
    public var eventType: String
    public var reason: String
    public var sourceApp: ClipboardSourceApp
    public var contentStored: Bool

    public init(capturedAt: Date, reason: String, sourceApp: ClipboardSourceApp) {
        self.capturedAt = capturedAt
        self.eventType = "blocked_sensitive_clipboard_item"
        self.reason = reason
        self.sourceApp = sourceApp
        self.contentStored = false
    }
}

