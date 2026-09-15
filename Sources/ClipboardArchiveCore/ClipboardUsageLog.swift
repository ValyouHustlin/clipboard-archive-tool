import Darwin
import Foundation

/// Content-free, local diagnostics. The API deliberately accepts no free-form
/// strings, event IDs, hashes, queries, app names, paths or Error values.
public struct ClipboardUsageLog: Sendable {
    public enum Event: String, Codable, Sendable {
        case appStart = "app_start", search, quickPicker = "quick_picker"
        case copyBack = "copy_back", capture, blocked
        case indexRebuild = "index_rebuild", error
    }

    public enum Outcome: String, Codable, Sendable {
        case success, hit, miss, failed, excluded, unavailable
    }

    public enum Scope: String, Codable, Sendable {
        case application, allHistory = "all_history", thisWindow = "this_window"
        case quickPicker = "quick_picker", archive, index
    }

    private struct Row: Encodable {
        let schema = 1
        let timestamp: Date
        let version: [Int]
        let build: Int
        let event: Event
        let outcome: Outcome
        let scope: Scope
        let count: Int
        let durationMs: Double
        let bytes: Int
    }

    public let directory: URL
    public let maximumFileBytes: Int
    public let retainedFiles: Int

    public init(archiveRoot: URL, maximumFileBytes: Int = 1_048_576, retainedFiles: Int = 5) {
        directory = archiveRoot.appendingPathComponent("usage", isDirectory: true)
        self.maximumFileBytes = max(512, maximumFileBytes)
        self.retainedFiles = max(1, min(10, retainedFiles))
    }

    /// Best effort: a busy log or disk error cannot interrupt a copy/capture.
    /// One nonblocking cross-process lock covers size-check, rotation and append.
    @discardableResult
    public func record(
        _ event: Event, outcome: Outcome = .success, scope: Scope = .application,
        count: Int = 1, durationMs: Double = 0, bytes: Int = 0
    ) -> Bool {
        do {
            try ClipboardPrivateFileSystem.createDirectory(directory, archiveRoot: directory.deletingLastPathComponent())
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

            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .custom { date, encoder in
                let formatter = ISO8601DateFormatter()
                formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                var container = encoder.singleValueContainer()
                try container.encode(formatter.string(from: date))
            }
            encoder.outputFormatting = [.sortedKeys]
            var data = try encoder.encode(Row(
                timestamp: Date(),
                version: (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "")
                    .split(separator: ".").prefix(4).compactMap { Int($0) },
                build: Int(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "") ?? 0,
                event: event, outcome: outcome, scope: scope,
                count: max(0, count), durationMs: durationMs.isFinite ? max(0, durationMs) : 0,
                bytes: max(0, bytes)
            ))
            data.append(0x0A)
            guard data.count <= maximumFileBytes else { return false }
            let current = "events.ndjson"
            var info = stat()
            let exists = fstatat(directoryFD, current, &info, AT_SYMLINK_NOFOLLOW) == 0
            guard !exists || (info.st_mode & S_IFMT) == S_IFREG else { return false }
            if Int(info.st_size) + data.count > maximumFileBytes {
                for number in stride(from: retainedFiles - 1, through: 0, by: -1) {
                    let source = number == 0 ? current : "events.\(number).ndjson"
                    let status = number == retainedFiles - 1
                        ? unlinkat(directoryFD, source, 0)
                        : renameat(directoryFD, source, directoryFD, "events.\(number + 1).ndjson")
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
}
