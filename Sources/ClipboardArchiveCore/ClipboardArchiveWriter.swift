import CryptoKit
import Foundation

public struct ClipboardArchiveWriter: Sendable {
    public var archiveRoot: URL
    public var inlineContentLimitBytes: Int
    public var calendar: Calendar

    public init(
        archiveRoot: URL,
        inlineContentLimitBytes: Int = 64 * 1024,
        calendar: Calendar = Calendar(identifier: .gregorian)
    ) {
        self.archiveRoot = archiveRoot
        self.inlineContentLimitBytes = inlineContentLimitBytes
        self.calendar = calendar
    }

    @discardableResult
    public func archiveAllowedCapture(_ capture: ClipboardCapture) throws -> StoredClipboardEvent {
        let contentData = Data(capture.content.utf8)
        let hash = sha256(contentData)
        let id = eventID(capturedAt: capture.capturedAt, hash: hash)
        let day = dayString(capture.capturedAt)
        let uiVisibleUntil = calendar.date(byAdding: .day, value: 7, to: capture.capturedAt) ?? capture.capturedAt
        var rawContentPath: String?
        var inlineContent: String?

        if contentData.count > inlineContentLimitBytes {
            let largeDirectory = archiveRoot
                .appendingPathComponent("raw")
                .appendingPathComponent(yearString(capture.capturedAt))
                .appendingPathComponent(monthString(capture.capturedAt))
                .appendingPathComponent("\(day)_large-items")
            try FileManager.default.createDirectory(at: largeDirectory, withIntermediateDirectories: true)
            let fileExtension = inferContentType(capture.content) == .code ? "code" : "txt"
            let bodyURL = largeDirectory.appendingPathComponent("\(id).\(fileExtension)")
            try contentData.write(to: bodyURL, options: [.atomic])
            rawContentPath = relativePath(from: archiveRoot, to: bodyURL)
        } else {
            inlineContent = capture.content
        }

        let event = StoredClipboardEvent(
            id: id,
            capturedAt: capture.capturedAt,
            contentType: inferContentType(capture.content),
            contentHash: "sha256:\(hash)",
            contentPreview: preview(capture.content),
            contentInline: inlineContent,
            rawContentPath: rawContentPath,
            sourceApp: capture.sourceApp,
            pasteboardTypes: capture.pasteboardTypes,
            byteCount: contentData.count,
            characterCount: capture.content.count,
            lineCount: capture.content.split(separator: "\n", omittingEmptySubsequences: false).count,
            privacyLabel: .privateLocal,
            allowedUse: [.localSearch, .localAnalysis],
            sensitivityFlags: [],
            uiVisibleUntil: uiVisibleUntil
        )

        try appendJSONLine(event, to: dailyEventsURL(for: capture.capturedAt))
        return event
    }

    public func archiveBlockedCapture(_ capture: ClipboardCapture, reason: String) throws {
        let event = BlockedClipboardEvent(
            capturedAt: capture.capturedAt,
            reason: reason,
            sourceApp: capture.sourceApp
        )
        try appendJSONLine(event, to: dailyEventsURL(for: capture.capturedAt))
    }

    private func dailyEventsURL(for date: Date) -> URL {
        archiveRoot
            .appendingPathComponent("raw")
            .appendingPathComponent(yearString(date))
            .appendingPathComponent(monthString(date))
            .appendingPathComponent("\(dayString(date))_clipboard-events.ndjson")
    }

    private func appendJSONLine<T: Encodable>(_ value: T, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        var data = try encoder.encode(value)
        data.append(0x0A)

        if FileManager.default.fileExists(atPath: url.path) {
            let handle = try FileHandle(forWritingTo: url)
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
            try handle.close()
        } else {
            try data.write(to: url, options: [.atomic])
        }
    }

    private func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func eventID(capturedAt: Date, hash: String) -> String {
        let compactDate = Self.compactFormatter.string(from: capturedAt)
        let uniqueSuffix = UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(8).lowercased()
        return "clip_\(compactDate)_\(hash.prefix(12))_\(uniqueSuffix)"
    }

    private func preview(_ text: String) -> String {
        let collapsed = text
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\t", with: " ")
        return String(collapsed.prefix(240))
    }

    private func inferContentType(_ text: String) -> ClipboardContentType {
        if URL(string: text.trimmingCharacters(in: .whitespacesAndNewlines))?.scheme != nil {
            return .url
        }

        let codeSignals = ["func ", "class ", "struct ", "import ", "{", "}", "const ", "let ", "var "]
        let signalCount = codeSignals.filter { text.contains($0) }.count
        return signalCount >= 2 ? .code : .text
    }

    private func relativePath(from root: URL, to child: URL) -> String {
        let rootPath = root.standardizedFileURL.path
        let childPath = child.standardizedFileURL.path
        if childPath.hasPrefix(rootPath + "/") {
            return String(childPath.dropFirst(rootPath.count + 1))
        }
        return childPath
    }

    private func yearString(_ date: Date) -> String {
        Self.yearFormatter.string(from: date)
    }

    private func monthString(_ date: Date) -> String {
        Self.monthFormatter.string(from: date)
    }

    private func dayString(_ date: Date) -> String {
        Self.dayFormatter.string(from: date)
    }

    private static let yearFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy"
        return formatter
    }()

    private static let monthFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "MM"
        return formatter
    }()

    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    private static let compactFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        return formatter
    }()
}
