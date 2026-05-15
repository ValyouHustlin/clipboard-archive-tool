import Foundation

public enum ClipboardContentType: String, Codable, Sendable {
    case text
    case url
    case code
    case blocked
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
        uiVisibleUntil: Date
    ) {
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

