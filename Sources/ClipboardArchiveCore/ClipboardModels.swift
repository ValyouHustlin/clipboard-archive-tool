import Foundation

/// Tolerant content type: known values decode to their named case, unknown
/// raw values decode losslessly to `.other(rawValue)` and re-encode as the
/// original string. This keeps older readers able to decode newer archives.
public enum ClipboardContentType: Codable, Equatable, Hashable, Sendable {
    case text
    case url
    case code
    case blocked
    /// Rich formats (Slice 6). Formatted links stay `.url` — a titled link
    /// IS a URL (`richContent.kind == "link"` carries the title), which
    /// keeps the Links filter, index rows, and old-build icons working.
    case image
    case fileReference
    case richText
    case color
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
        case "image":
            self = .image
        case "file-reference":
            self = .fileReference
        case "rich-text":
            self = .richText
        case "color":
            self = .color
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
        case .image:
            return "image"
        case .fileReference:
            return "file-reference"
        case .richText:
            return "rich-text"
        case .color:
            return "color"
        case let .other(raw):
            return raw
        }
    }

    /// The one shared SF Symbol mapping for every content-type icon surface
    /// (history rows, quick picker rows). Kept in Core so the panel and the
    /// picker cannot drift apart.
    public var systemSymbolName: String {
        switch self {
        case .text:
            return "doc.text"
        case .url:
            return "link"
        case .code:
            return "chevron.left.forwardslash.chevron.right"
        case .blocked:
            return "hand.raised.fill"
        case .image:
            return "photo"
        case .fileReference:
            return "doc.on.doc"
        case .richText:
            return "textformat"
        case .color:
            return "paintpalette"
        case .other:
            return "questionmark.square.dashed"
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

/// One file entry inside a file-reference clip (Slice 6). Stores metadata
/// ONLY — file contents are never copied into the archive (contract 7).
public struct ClipboardRichFileReference: Codable, Equatable, Sendable {
    public var name: String
    public var path: String
    public var byteCount: Int?
    public var uti: String?

    public init(name: String, path: String, byteCount: Int? = nil, uti: String? = nil) {
        self.name = name
        self.path = path
        self.byteCount = byteCount
        self.uti = uti
    }

    private enum CodingKeys: String, CodingKey {
        case name
        case path
        case byteCount
        case uti
    }

    /// Tolerant decode (contract 1): only name/path are required in spirit;
    /// missing keys degrade to empty rather than failing the whole line.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? ""
        path = try container.decodeIfPresent(String.self, forKey: .path) ?? ""
        byteCount = try container.decodeIfPresent(Int.self, forKey: .byteCount)
        uti = try container.decodeIfPresent(String.self, forKey: .uti)
    }
}

/// The ONE tolerant rich-content field on `StoredClipboardEvent` (Slice 6,
/// schema v2). `rawContentPath` stays plain-text-only forever; rich binary
/// bodies live exclusively in `bodyPath` — that separation is what makes
/// old-build fallback (preview text, plain copy) safe by construction.
public struct ClipboardRichContent: Codable, Equatable, Sendable {
    /// Known kinds: "image", "rtf", "file-list", "color", "link". Unknown
    /// values from newer builds round-trip losslessly.
    public static let imageKind = "image"
    public static let rtfKind = "rtf"
    public static let fileListKind = "file-list"
    public static let colorKind = "color"
    public static let linkKind = "link"

    public var kind: String
    /// Relative, containment-checked path to the rich body file under the
    /// existing large-items layout. Nil for inline-only kinds (color, link,
    /// small file lists).
    public var bodyPath: String?
    public var bodyByteCount: Int?
    /// UTI of the body bytes (e.g. "public.png", "public.tiff").
    public var bodyType: String?
    public var imagePixelWidth: Int?
    public var imagePixelHeight: Int?
    /// Inline file entries (first 100; the FULL list spills into the
    /// `<id>.json` body when truncated).
    public var files: [ClipboardRichFileReference]?
    public var fileCount: Int?
    public var filesTruncated: Bool?
    public var colorHex: String?
    public var colorSpace: String?
    public var linkURL: String?
    public var linkTitle: String?
    /// True when `capture.content` carried a usable plain-text fallback
    /// (everything except images).
    public var hasPlainTextFallback: Bool

    public init(
        kind: String,
        bodyPath: String? = nil,
        bodyByteCount: Int? = nil,
        bodyType: String? = nil,
        imagePixelWidth: Int? = nil,
        imagePixelHeight: Int? = nil,
        files: [ClipboardRichFileReference]? = nil,
        fileCount: Int? = nil,
        filesTruncated: Bool? = nil,
        colorHex: String? = nil,
        colorSpace: String? = nil,
        linkURL: String? = nil,
        linkTitle: String? = nil,
        hasPlainTextFallback: Bool = true
    ) {
        self.kind = kind
        self.bodyPath = bodyPath
        self.bodyByteCount = bodyByteCount
        self.bodyType = bodyType
        self.imagePixelWidth = imagePixelWidth
        self.imagePixelHeight = imagePixelHeight
        self.files = files
        self.fileCount = fileCount
        self.filesTruncated = filesTruncated
        self.colorHex = colorHex
        self.colorSpace = colorSpace
        self.linkURL = linkURL
        self.linkTitle = linkTitle
        self.hasPlainTextFallback = hasPlainTextFallback
    }

    private enum CodingKeys: String, CodingKey {
        case kind
        case bodyPath
        case bodyByteCount
        case bodyType
        case imagePixelWidth
        case imagePixelHeight
        case files
        case fileCount
        case filesTruncated
        case colorHex
        case colorSpace
        case linkURL
        case linkTitle
        case hasPlainTextFallback
    }

    /// Tolerant decode (contract 1): every field after `kind` is optional
    /// with a safe default so future additions never fail an archive line.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        kind = try container.decodeIfPresent(String.self, forKey: .kind) ?? ""
        bodyPath = try container.decodeIfPresent(String.self, forKey: .bodyPath)
        bodyByteCount = try container.decodeIfPresent(Int.self, forKey: .bodyByteCount)
        bodyType = try container.decodeIfPresent(String.self, forKey: .bodyType)
        imagePixelWidth = try container.decodeIfPresent(Int.self, forKey: .imagePixelWidth)
        imagePixelHeight = try container.decodeIfPresent(Int.self, forKey: .imagePixelHeight)
        files = try container.decodeIfPresent([ClipboardRichFileReference].self, forKey: .files)
        fileCount = try container.decodeIfPresent(Int.self, forKey: .fileCount)
        filesTruncated = try container.decodeIfPresent(Bool.self, forKey: .filesTruncated)
        colorHex = try container.decodeIfPresent(String.self, forKey: .colorHex)
        colorSpace = try container.decodeIfPresent(String.self, forKey: .colorSpace)
        linkURL = try container.decodeIfPresent(String.self, forKey: .linkURL)
        linkTitle = try container.decodeIfPresent(String.self, forKey: .linkTitle)
        hasPlainTextFallback = try container.decodeIfPresent(Bool.self, forKey: .hasPlainTextFallback) ?? true
    }
}

/// Capture-time rich payload (Slice 6). Carried alongside the plain-text
/// fallback in `ClipboardCapture.rich`; never persisted directly — the
/// writer turns it into `ClipboardRichContent` + body files.
public enum ClipboardRichPayload: Equatable, Sendable {
    case image(data: Data, uti: String, pixelWidth: Int?, pixelHeight: Int?)
    case rtf(data: Data)
    case fileList([ClipboardRichFileReference])
    case color(hex: String, colorSpace: String)
    case link(url: String, title: String)

    /// Canonical bytes for content identity + dedup, per the storage table:
    /// image = image bytes, rtf = RTF bytes, file-list = joined paths,
    /// color = hex, link = url + "\n" + title.
    public var canonicalHashData: Data {
        switch self {
        case let .image(data, _, _, _):
            return data
        case let .rtf(data):
            return data
        case let .fileList(files):
            return Data(files.map(\.path).joined(separator: "\n").utf8)
        case let .color(hex, _):
            return Data(hex.utf8)
        case let .link(url, title):
            return Data((url + "\n" + title).utf8)
        }
    }
}

/// The ONE per-kind dedup value shared by the capture poll and every
/// copy-back path (design: identical `dedupHashValue` on both sides so a
/// copied-back clip is never re-captured, and a genuine re-copy of the same
/// rich content is skipped exactly like text).
public enum ClipboardCaptureDedup {
    public static func value(content: String, rich: ClipboardRichPayload?) -> Int {
        guard let rich else {
            return content.hashValue
        }
        return rich.canonicalHashData.hashValue
    }
}

public struct ClipboardCapture: Equatable, Sendable {
    public var capturedAt: Date
    public var content: String
    public var sourceApp: ClipboardSourceApp
    public var pasteboardTypes: [String]
    /// Optional rich payload (Slice 6). `content` is ALWAYS the plain-text
    /// fallback (empty for images) — the filter/secret-detector/FTS
    /// substrate.
    public var rich: ClipboardRichPayload?

    public init(
        capturedAt: Date = Date(),
        content: String,
        sourceApp: ClipboardSourceApp,
        pasteboardTypes: [String] = [],
        rich: ClipboardRichPayload? = nil
    ) {
        self.capturedAt = capturedAt
        self.content = content
        self.sourceApp = sourceApp
        self.pasteboardTypes = pasteboardTypes
        self.rich = rich
    }
}

public struct StoredClipboardEvent: Codable, Equatable, Sendable {
    /// Bump only for semantic changes to the event schema. Fields added after
    /// version 1 must decode with `decodeIfPresent` and a safe default; no new
    /// required fields, ever, within the NDJSON format (expansion contract 1).
    ///
    /// Version 2 (Slice 6): the tolerant `richContent` field. PER-LINE
    /// STAMPING (contract 1 amendment): a line's `schemaVersion` reflects
    /// the newest schema feature it actually uses — the writer stamps 1 for
    /// text-only events (so existing text lines stay byte-identical) and 2
    /// only when `richContent` is present.
    public static let currentSchemaVersion = 2

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
    /// Rich-format metadata (Slice 6, schema v2). Nil for plain text events
    /// — and omitted from their encoded lines, keeping text lines
    /// byte-identical to version 1 output.
    public var richContent: ClipboardRichContent?

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
        schemaVersion: Int = StoredClipboardEvent.currentSchemaVersion,
        richContent: ClipboardRichContent? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.richContent = richContent
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
        case richContent
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
        // Version 2 field (Slice 6): tolerant — v1 lines decode nil.
        richContent = try container.decodeIfPresent(ClipboardRichContent.self, forKey: .richContent)
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

