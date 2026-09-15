import Darwin
import Foundation

/// The rotating, cross-process-serialised NDJSON appender that every
/// content-free local log writes through.
///
/// One nonblocking `flock` covers the size check, the rotation and the
/// append, so two processes can never interleave half a row or rotate the
/// same file twice. Every descriptor is opened `O_NOFOLLOW` and re-checked
/// as a regular file, so a symlink planted at a log path can never redirect
/// a write; the directory is held at 0700 and each file at 0600.
///
/// Every call is best effort: a busy lock, a full disk or a hostile path
/// returns `false` and never throws into the caller. A log that cannot be
/// written must not interrupt a copy, a capture or a launch.
public struct ClipboardRotatingLogFile: Sendable {
    public let directory: URL
    /// File stem: the live file is `<baseName>.ndjson`, rotated generations
    /// are `<baseName>.1.ndjson` … `<baseName>.<retainedFiles - 1>.ndjson`.
    public let baseName: String
    public let maximumFileBytes: Int
    public let retainedFiles: Int

    public init(directory: URL, baseName: String, maximumFileBytes: Int, retainedFiles: Int) {
        self.directory = directory
        self.baseName = baseName
        self.maximumFileBytes = max(512, maximumFileBytes)
        self.retainedFiles = max(1, min(10, retainedFiles))
    }

    /// Appends one already-encoded row. The caller passes the row WITHOUT a
    /// trailing newline; the terminator is added here so a row can never be
    /// written without one.
    @discardableResult
    public func append(_ row: Data) -> Bool {
        do {
            try ClipboardPrivateFileSystem.createDirectory(
                directory,
                archiveRoot: directory.deletingLastPathComponent()
            )
            let directoryFD = open(directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
            guard directoryFD >= 0 else { return false }
            defer { close(directoryFD) }
            guard fchmod(directoryFD, 0o700) == 0 else { return false }
            let lockFD = openat(directoryFD, ".lock", O_CREAT | O_RDWR | O_NOFOLLOW | O_NONBLOCK, 0o600)
            guard lockFD >= 0 else { return false }
            defer { close(lockFD) }
            var lockInfo = stat()
            guard fstat(lockFD, &lockInfo) == 0, (lockInfo.st_mode & S_IFMT) == S_IFREG,
                  fchmod(lockFD, 0o600) == 0,
                  flock(lockFD, LOCK_EX | LOCK_NB) == 0 else { return false }
            defer { flock(lockFD, LOCK_UN) }

            var data = row
            data.append(0x0A)
            guard data.count <= maximumFileBytes else { return false }
            let current = "\(baseName).ndjson"
            var info = stat()
            let exists = fstatat(directoryFD, current, &info, AT_SYMLINK_NOFOLLOW) == 0
            guard !exists || (info.st_mode & S_IFMT) == S_IFREG else { return false }
            if Int(info.st_size) + data.count > maximumFileBytes {
                for number in stride(from: retainedFiles - 1, through: 0, by: -1) {
                    let source = number == 0 ? current : "\(baseName).\(number).ndjson"
                    let status = number == retainedFiles - 1
                        ? unlinkat(directoryFD, source, 0)
                        : renameat(directoryFD, source, directoryFD, "\(baseName).\(number + 1).ndjson")
                    guard status == 0 || errno == ENOENT else { return false }
                }
            }
            let fd = openat(directoryFD, current, O_WRONLY | O_APPEND | O_CREAT | O_NOFOLLOW | O_NONBLOCK, 0o600)
            guard fd >= 0 else { return false }
            defer { close(fd) }
            guard fstat(fd, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG,
                  fchmod(fd, 0o600) == 0 else { return false }
            let originalSize = info.st_size
            return data.withUnsafeBytes { buffer in
                var offset = 0
                while offset < buffer.count {
                    let written = write(fd, buffer.baseAddress!.advanced(by: offset), buffer.count - offset)
                    if written < 0 && errno == EINTR { continue }
                    guard written > 0 else {
                        // Avoid leaving a partial JSON row after a short write.
                        _ = ftruncate(fd, originalSize)
                        return false
                    }
                    offset += written
                }
                return true
            }
        } catch {
            return false
        }
    }

    /// The live file first, then older generations — the order a reader
    /// walks when it wants newest-first, reversed when it wants oldest-first.
    public var files: [URL] {
        (0..<retainedFiles).map { number in
            directory.appendingPathComponent(
                number == 0 ? "\(baseName).ndjson" : "\(baseName).\(number).ndjson"
            )
        }
    }

    /// The shared encoder for every content-free row: sorted keys so a row
    /// is byte-stable, and UTC ISO 8601 with milliseconds for timestamps.
    public static func rowEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .custom { date, encoder in
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            var container = encoder.singleValueContainer()
            try container.encode(formatter.string(from: date))
        }
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }

    /// The bundle's marketing version as integer components, and its build
    /// number — the two identity fields every row carries.
    public static func bundleVersion(_ bundle: Bundle = .main) -> (version: [Int], build: Int) {
        let version = (bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "")
            .split(separator: ".").prefix(4).compactMap { Int($0) }
        let build = Int(bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "") ?? 0
        return (version, build)
    }
}
