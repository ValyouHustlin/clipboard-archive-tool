import Darwin
import Foundation

extension Data {
    /// Foundation's atomic writer can request a replacement directory outside
    /// an application's scratch root. Keep scratch temporaries beside their
    /// destination; production retains Foundation's established behavior.
    public func writeClipboardAtomically(to destination: URL) throws {
        guard ClipboardRuntime.isIsolated else {
            try write(to: destination, options: .atomic)
            return
        }
        let temporary = destination.deletingLastPathComponent()
            .appendingPathComponent(".clipboard-write-\(UUID().uuidString)")
        let fd = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { close(fd); unlink(temporary.path) }
        try withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let written = Darwin.write(fd, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                if written < 0 && errno == EINTR { continue }
                guard written > 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
                offset += written
            }
        }
        guard fsync(fd) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        guard rename(temporary.path, destination.path) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        // Rename is the commit boundary: no later housekeeping may throw.
    }
}

extension String {
    public func writeClipboardAtomically(to destination: URL) throws {
        try Data(utf8).writeClipboardAtomically(to: destination)
    }
}
