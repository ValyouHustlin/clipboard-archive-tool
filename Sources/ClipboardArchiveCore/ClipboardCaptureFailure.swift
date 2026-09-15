import Darwin
import Foundation

/// Why a capture could not be archived, reduced to a closed set of classes
/// with a short user-facing label.
///
/// The label never carries a path, a file name, an error message or any
/// clipboard content: the capture path reports failures in the menu, and a
/// status line is a surface a person can screen-share. Classification walks
/// the underlying-error chain, because a file write failure usually arrives
/// as a Cocoa error wrapping the POSIX code that actually explains it.
public enum ClipboardCaptureFailure: String, Sendable, Equatable, CaseIterable {
    case diskFull
    case permissionDenied
    case readOnlyVolume
    case archiveMissing
    case other

    /// Short, content-free wording for the menu status line.
    public var label: String {
        switch self {
        case .diskFull:
            return "Disk full"
        case .permissionDenied:
            return "Permission denied"
        case .readOnlyVolume:
            return "Read-only volume"
        case .archiveMissing:
            return "Archive folder missing"
        case .other:
            return "Write failed"
        }
    }

    /// The POSIX code that stands for this class in an operational row —
    /// the reason class as a number, with no message attached. `other`
    /// carries 0 because it names no specific errno.
    public var posixCode: Int32 {
        switch self {
        case .diskFull:
            return ENOSPC
        case .permissionDenied:
            return EACCES
        case .readOnlyVolume:
            return EROFS
        case .archiveMissing:
            return ENOENT
        case .other:
            return 0
        }
    }

    public static func classify(_ error: Error) -> ClipboardCaptureFailure {
        for nsError in errorChain(error) {
            // `Int32(_:)` traps on an out-of-range code, and this runs on
            // the capture path: an odd error value must never crash capture.
            if nsError.domain == NSPOSIXErrorDomain,
               let code = Int32(exactly: nsError.code),
               let failure = fromPOSIXCode(code) {
                return failure
            }
            if nsError.domain == NSCocoaErrorDomain,
               let failure = fromCocoaCode(nsError.code) {
                return failure
            }
        }
        return .other
    }

    private static func fromPOSIXCode(_ code: Int32) -> ClipboardCaptureFailure? {
        switch code {
        case ENOSPC, EDQUOT:
            return .diskFull
        case EACCES, EPERM:
            return .permissionDenied
        case EROFS:
            return .readOnlyVolume
        case ENOENT:
            return .archiveMissing
        default:
            return nil
        }
    }

    private static func fromCocoaCode(_ code: Int) -> ClipboardCaptureFailure? {
        switch code {
        case NSFileWriteOutOfSpaceError:
            return .diskFull
        case NSFileWriteNoPermissionError, NSFileReadNoPermissionError:
            return .permissionDenied
        case NSFileWriteVolumeReadOnlyError:
            return .readOnlyVolume
        case NSFileNoSuchFileError, NSFileReadNoSuchFileError:
            return .archiveMissing
        default:
            return nil
        }
    }

    /// The error itself followed by its underlying errors, outermost first,
    /// with a depth bound so a cyclic chain cannot spin the capture path.
    private static func errorChain(_ error: Error) -> [NSError] {
        var chain: [NSError] = []
        var current: NSError? = error as NSError
        while let nsError = current, chain.count < 8 {
            chain.append(nsError)
            current = nsError.userInfo[NSUnderlyingErrorKey] as? NSError
        }
        return chain
    }
}
