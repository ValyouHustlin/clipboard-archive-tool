import CryptoKit
import Darwin
import Foundation

/// A day-file append that could not complete, carrying the `errno` that
/// stopped it. `CustomNSError` files it under `NSPOSIXErrorDomain`, so the
/// capture-failure classifier reduces it through the POSIX chain it already
/// walks — a full disk reads as "Disk full", not "Write failed".
public struct ClipboardArchiveAppendError: Error, CustomNSError, Equatable, Sendable {
    public let errnoValue: Int32

    public init(errnoValue: Int32) {
        self.errnoValue = errnoValue
    }

    public static var errorDomain: String {
        NSPOSIXErrorDomain
    }

    public var errorCode: Int {
        Int(errnoValue)
    }
}

public struct ClipboardArchiveWriter: Sendable {
    /// Test-only fault seam for the short-write branch: the append writes at
    /// most `bytesBeforeFailure` bytes of a row and then fails with
    /// `errnoValue`, exactly as a volume filling mid-row does. Never set on
    /// any shipping path — there is no initialiser parameter for it.
    struct AppendFault: Equatable, Sendable {
        var bytesBeforeFailure: Int
        var errnoValue: Int32

        init(bytesBeforeFailure: Int, errnoValue: Int32) {
            self.bytesBeforeFailure = bytesBeforeFailure
            self.errnoValue = errnoValue
        }
    }

    public var archiveRoot: URL
    public var inlineContentLimitBytes: Int
    public var calendar: Calendar
    /// Operational sink for append repairs, set by the surface that resolved
    /// it (the ingestor propagates its own). Nil means silent.
    public var operationalLog: ClipboardOperationalLog?
    var appendFault: AppendFault?

    public init(
        archiveRoot: URL,
        inlineContentLimitBytes: Int = 64 * 1024,
        calendar: Calendar = Calendar(identifier: .gregorian)
    ) {
        self.archiveRoot = archiveRoot
        self.inlineContentLimitBytes = inlineContentLimitBytes
        self.calendar = calendar
    }

    /// Content identity for a capture body, matching the stored
    /// `contentHash` field exactly (`sha256:<hex>`). Shared so the ingestor
    /// can consult content-keyed annotations BEFORE the event is written.
    public static func contentHash(for content: String) -> String {
        let data = Data(content.utf8)
        return "sha256:" + SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// Per-kind content identity (Slice 6): rich captures hash their
    /// canonical bytes (image/RTF bytes, joined paths, hex, url+title);
    /// text captures keep hashing the UTF-8 content unchanged.
    public static func contentHash(for capture: ClipboardCapture) -> String {
        guard let rich = capture.rich else {
            return contentHash(for: capture.content)
        }
        let digest = SHA256.hash(data: rich.canonicalHashData)
        return "sha256:" + digest.map { String(format: "%02x", $0) }.joined()
    }

    /// Archives one allowed capture. `privacyLabel` defaults to the
    /// historical `.privateLocal`; per-app `store-no-index` rules pass
    /// `.restricted` (stored, visible, never searchable — Slice 5).
    /// `sensitivityFlags` are persisted on the event line.
    /// Maximum inline file entries on the event line; longer lists spill the
    /// FULL list into a `<id>.json` body (Slice 6 design).
    public static let inlineFileListLimit = 100

    @discardableResult
    public func archiveAllowedCapture(
        _ capture: ClipboardCapture,
        privacyLabel: PrivacyLabel = .privateLocal,
        sensitivityFlags: [String] = []
    ) throws -> StoredClipboardEvent {
        try ensureArchiveFormatMarker()
        let contentData = Data(capture.content.utf8)
        // Per-kind content identity (Slice 6): rich captures hash their
        // canonical bytes; text keeps hashing the UTF-8 content unchanged.
        let hash = sha256(capture.rich?.canonicalHashData ?? contentData)
        let id = eventID(capturedAt: capture.capturedAt, hash: hash)
        let day = dayString(capture.capturedAt)
        let uiVisibleUntil = calendar.date(byAdding: .day, value: 7, to: capture.capturedAt) ?? capture.capturedAt
        var rawContentPath: String?
        var inlineContent: String?
        /// Every body file written before the NDJSON append, so an append
        /// failure can delete them all (no orphaned bodies — this also
        /// fixes the pre-existing text-body leak).
        var bodyFilesWritten: [URL] = []
        var committed = false
        defer {
            if !committed { for url in bodyFilesWritten { try? FileManager.default.removeItem(at: url) } }
        }

        func largeItemsDirectory() throws -> URL {
            let directory = archiveRoot
                .appendingPathComponent("raw")
                .appendingPathComponent(yearString(capture.capturedAt))
                .appendingPathComponent(monthString(capture.capturedAt))
                .appendingPathComponent("\(day)_large-items")
            try ClipboardPrivateFileSystem.createDirectory(directory, archiveRoot: archiveRoot)
            return directory
        }

        func writeBody(_ data: Data, fileExtension: String) throws -> URL {
            let bodyURL = try largeItemsDirectory().appendingPathComponent("\(id).\(fileExtension)")
            try data.writeClipboardAtomically(to: bodyURL)
            bodyFilesWritten.append(bodyURL)
            try ClipboardPrivateFileSystem.secureFile(bodyURL)
            return bodyURL
        }

        // Plain-text fallback storage — the EXISTING inline/txt rules,
        // unchanged. Images have no plain fallback (design: inline never;
        // `rawContentPath` stays plain-text-only forever).
        var isImageCapture = false
        if case .image = capture.rich {
            isImageCapture = true
        }
        if !isImageCapture {
            if contentData.count > inlineContentLimitBytes {
                let fileExtension = inferContentType(capture.content) == .code ? "code" : "txt"
                let bodyURL = try writeBody(contentData, fileExtension: fileExtension)
                rawContentPath = relativePath(from: archiveRoot, to: bodyURL)
            } else {
                inlineContent = capture.content
            }
        }

        // Rich metadata + rich body files (Slice 6). Rich bytes live ONLY
        // in `richContent.bodyPath`.
        var richContent: ClipboardRichContent?
        var contentType = inferContentType(capture.content)
        var contentPreview = preview(capture.content)
        var byteCount = contentData.count

        switch capture.rich {
        case let .image(data, uti, pixelWidth, pixelHeight):
            let fileExtension = uti == "public.tiff" ? "tiff" : "png"
            let bodyURL = try writeBody(data, fileExtension: fileExtension)
            richContent = ClipboardRichContent(
                kind: ClipboardRichContent.imageKind,
                bodyPath: relativePath(from: archiveRoot, to: bodyURL),
                bodyByteCount: data.count,
                bodyType: uti,
                imagePixelWidth: pixelWidth,
                imagePixelHeight: pixelHeight,
                hasPlainTextFallback: false
            )
            contentType = .image
            contentPreview = Self.imagePreview(
                pixelWidth: pixelWidth,
                pixelHeight: pixelHeight,
                byteCount: data.count
            )
            byteCount = data.count

        case let .rtf(data):
            let bodyURL = try writeBody(data, fileExtension: "rtf")
            richContent = ClipboardRichContent(
                kind: ClipboardRichContent.rtfKind,
                bodyPath: relativePath(from: archiveRoot, to: bodyURL),
                bodyByteCount: data.count,
                bodyType: "public.rtf",
                hasPlainTextFallback: true
            )
            contentType = .richText
            byteCount = data.count

        case let .fileList(files):
            var bodyPath: String?
            var bodyByteCount: Int?
            var truncated: Bool?
            if files.count > Self.inlineFileListLimit {
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
                let fullList = try encoder.encode(files)
                let bodyURL = try writeBody(fullList, fileExtension: "json")
                bodyPath = relativePath(from: archiveRoot, to: bodyURL)
                bodyByteCount = fullList.count
                truncated = true
            }
            richContent = ClipboardRichContent(
                kind: ClipboardRichContent.fileListKind,
                bodyPath: bodyPath,
                bodyByteCount: bodyByteCount,
                bodyType: bodyPath == nil ? nil : "public.json",
                files: Array(files.prefix(Self.inlineFileListLimit)),
                fileCount: files.count,
                filesTruncated: truncated,
                hasPlainTextFallback: true
            )
            contentType = .fileReference
            contentPreview = Self.fileListPreview(files)

        case let .color(hex, colorSpace):
            richContent = ClipboardRichContent(
                kind: ClipboardRichContent.colorKind,
                colorHex: hex,
                colorSpace: colorSpace,
                hasPlainTextFallback: true
            )
            contentType = .color
            contentPreview = String("Color \(hex)".prefix(240))

        case let .link(url, title):
            richContent = ClipboardRichContent(
                kind: ClipboardRichContent.linkKind,
                linkURL: url,
                linkTitle: title,
                hasPlainTextFallback: true
            )
            // A titled link stays contentType "url" (design decision: keeps
            // the Links filter, index rows, and old-build icons working).
            contentType = .url
            contentPreview = String("\(title) — \(url)".prefix(240))

        case nil:
            break
        }

        let event = StoredClipboardEvent(
            id: id,
            capturedAt: capture.capturedAt,
            contentType: contentType,
            contentHash: "sha256:\(hash)",
            contentPreview: contentPreview,
            contentInline: inlineContent,
            rawContentPath: rawContentPath,
            sourceApp: capture.sourceApp,
            pasteboardTypes: capture.pasteboardTypes,
            byteCount: byteCount,
            characterCount: capture.content.count,
            lineCount: capture.content.split(separator: "\n", omittingEmptySubsequences: false).count,
            privacyLabel: privacyLabel,
            allowedUse: privacyLabel == .restricted
                ? [.archiveOnly]
                : [.localSearch, .localAnalysis],
            sensitivityFlags: sensitivityFlags.sorted(),
            uiVisibleUntil: uiVisibleUntil,
            // PER-LINE STAMPING (contract 1 amendment): text-only lines keep
            // stamping 1 so they stay byte-identical to pre-Slice-6 output;
            // only lines actually carrying richContent stamp 2.
            schemaVersion: richContent == nil ? 1 : 2,
            richContent: richContent
        )

        do {
            try appendJSONLine(event, to: dailyEventsURL(for: capture.capturedAt))
        } catch {
            // Fail closed: without the NDJSON line no reader can ever reach
            // these bodies, so delete them instead of leaking orphans.
            for url in bodyFilesWritten where FileManager.default.fileExists(atPath: url.path) {
                try? FileManager.default.removeItem(at: url)
            }
            throw error
        }
        committed = true
        return event
    }

    static func imagePreview(pixelWidth: Int?, pixelHeight: Int?, byteCount: Int) -> String {
        let size = ByteCountFormatter.string(fromByteCount: Int64(byteCount), countStyle: .file)
        if let pixelWidth, let pixelHeight {
            return "Image \(pixelWidth)×\(pixelHeight) (\(size))"
        }
        return "Image (\(size))"
    }

    static func fileListPreview(_ files: [ClipboardRichFileReference]) -> String {
        let count = files.count
        let shownNames = files.prefix(5).map(\.name).joined(separator: ", ")
        let suffix = count > 5 ? "…" : ""
        let text = "\(count) file\(count == 1 ? "" : "s"): \(shownNames)\(suffix)"
        return String(text.prefix(240))
    }

    public func archiveBlockedCapture(_ capture: ClipboardCapture, reason: String) throws {
        try ensureArchiveFormatMarker()
        let event = BlockedClipboardEvent(
            capturedAt: capture.capturedAt,
            reason: reason,
            sourceApp: capture.sourceApp
        )
        try appendJSONLine(event, to: dailyEventsURL(for: capture.capturedAt))
    }

    /// Ensures `<archiveRoot>/archive-format.json` before committing an event.
    /// A failed metadata write must not follow an accepted event. Never rewrites an existing
    /// marker; absence of the file means format 1 (expansion contract 1).
    private func ensureArchiveFormatMarker() throws {
        try ClipboardPrivateFileSystem.createDirectory(archiveRoot, archiveRoot: archiveRoot)
        let markerURL = archiveRoot.appendingPathComponent("archive-format.json")
        guard !FileManager.default.fileExists(atPath: markerURL.path) else {
            return
        }
        let marker = Data("{\"archiveFormatVersion\":1,\"minReader\":1}\n".utf8)
        try marker.writeClipboardAtomically(to: markerURL)
        try ClipboardPrivateFileSystem.secureFile(markerURL)
    }

    private func dailyEventsURL(for date: Date) -> URL {
        archiveRoot
            .appendingPathComponent("raw")
            .appendingPathComponent(yearString(date))
            .appendingPathComponent(monthString(date))
            .appendingPathComponent("\(dayString(date))_clipboard-events.ndjson")
    }

    /// Appends one row to the NDJSON day file so that no failure can cost
    /// more than the row being written.
    ///
    /// Three properties, in order:
    /// 1. BOUNDARY. A process killed between a row's bytes and its newline
    ///    leaves a tail with no terminator; appending onto it would glue two
    ///    rows into one unparsable line, so one torn row would destroy two.
    ///    A non-empty file whose last byte is not `\n` gets that one byte
    ///    first, which turns the fragment into exactly ONE invalid line.
    /// 2. ALL-OR-NOTHING. The row goes out through a `write(2)` loop; a
    ///    short write or an error truncates back to the size the file had
    ///    before this row (never below the pre-existing tail), so a reader
    ///    never meets half a row.
    /// 3. TYPED FAILURE. The caller gets the `errno` that stopped the write,
    ///    which is what the capture path classifies and records.
    ///
    /// No `fsync`: the archive is an append-only log and the cost of a
    /// per-capture flush is not justified. A power cut can therefore lose
    /// the last row, and the boundary check above is what makes that loss
    /// self-healing on the next append. Deliberate, not an oversight.
    private func appendJSONLine<T: Encodable>(_ value: T, to url: URL) throws {
        try ClipboardPrivateFileSystem.createDirectory(
            url.deletingLastPathComponent(),
            archiveRoot: archiveRoot
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        var data = try encoder.encode(value)
        data.append(0x0A)
        // Under the archive write lock, so a day-file rewrite can never read
        // the file, miss this row, and replace the file without it.
        try ClipboardArchiveWriteLock.withLock(archiveRoot: archiveRoot) {
            try appendEncodedLine(data, to: url)
        }
    }

    private func appendEncodedLine(_ data: Data, to url: URL) throws {
        // O_NOFOLLOW + a regular-file re-check: a symlink planted at a day
        // file path can never redirect an append (the log appender's rule).
        let descriptor = open(url.path, O_RDWR | O_APPEND | O_CREAT | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else {
            throw ClipboardArchiveAppendError(errnoValue: errno)
        }
        defer {
            close(descriptor)
        }
        var info = stat()
        guard fstat(descriptor, &info) == 0 else {
            throw ClipboardArchiveAppendError(errnoValue: errno)
        }
        guard (info.st_mode & S_IFMT) == S_IFREG else {
            throw ClipboardArchiveAppendError(errnoValue: EFTYPE)
        }

        var boundary = info.st_size
        if boundary > 0 {
            var lastByte: UInt8 = 0
            let read = pread(descriptor, &lastByte, 1, boundary - 1)
            if read < 0 {
                throw ClipboardArchiveAppendError(errnoValue: errno)
            }
            // Zero bytes means the file shrank under us; `errno` says
            // nothing about that, so it gets a fixed code rather than a
            // stale one that would classify at random.
            guard read == 1 else {
                throw ClipboardArchiveAppendError(errnoValue: EIO)
            }
            if lastByte != 0x0A {
                try writeAll(Data([0x0A]), to: descriptor, truncatingBackTo: boundary)
                boundary += 1
                operationalLog?.record(.archiveTailRepaired, count: 1)
            }
        }
        try writeAll(data, to: descriptor, truncatingBackTo: boundary)
        try ClipboardPrivateFileSystem.secureFile(url)
    }

    /// Writes every byte or leaves the file at `boundary`. `O_APPEND` keeps
    /// each write atomic against other appenders; the truncate assumes no
    /// other writer is mid-row, which the archive write lock held by the
    /// caller guarantees for the app and its CLI.
    private func writeAll(_ data: Data, to descriptor: Int32, truncatingBackTo boundary: off_t) throws {
        var budget = appendFault.map { $0.bytesBeforeFailure } ?? Int.max
        let failureErrno = appendFault?.errnoValue ?? EIO
        var partialBytes = 0
        let failure: Int32? = data.withUnsafeBytes { buffer -> Int32? in
            var offset = 0
            while offset < buffer.count {
                let remaining = min(buffer.count - offset, budget)
                guard remaining > 0 else {
                    partialBytes = offset
                    return failureErrno
                }
                let written = write(descriptor, buffer.baseAddress!.advanced(by: offset), remaining)
                if written < 0 && errno == EINTR {
                    continue
                }
                guard written > 0 else {
                    partialBytes = offset
                    return written < 0 ? errno : ENOSPC
                }
                offset += written
                budget -= written
            }
            return nil
        }
        guard let failure else {
            return
        }
        // Truncate ONLY the partial row this call wrote. If the file has
        // grown past that — another process appended a whole row of its own
        // through its own O_APPEND write — cutting back would delete their
        // committed data, and one unreadable line is the smaller loss.
        var info = stat()
        if fstat(descriptor, &info) == 0, info.st_size == boundary + off_t(partialBytes) {
            _ = ftruncate(descriptor, boundary)
        }
        throw ClipboardArchiveAppendError(errnoValue: failure)
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
