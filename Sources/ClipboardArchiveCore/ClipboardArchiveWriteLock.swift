import Darwin
import Foundation

/// One writer at a time for the archive's day files.
///
/// A capture appends a line to today's file. A delete, a prune, an expiry
/// sweep, a retention pass and a restore each read a day file, build a new
/// copy and replace the old one. Without a lock, a line appended between
/// that read and that replace is in the old file only, and is gone when the
/// replace lands. This lock closes that window: the append and every
/// read-then-replace take it.
///
/// It is an exclusive `flock` on the archive folder itself. That adds no file
/// to the archive (backups and health checks report files they do not
/// expect), it is released by the kernel if its holder dies, and it holds
/// between the app and the command-line tool as well as between threads,
/// because each acquisition opens its own descriptor.
///
/// Hold it for as little as possible: the capture path runs on the app's main
/// thread and waits here. One day file's read-and-replace is the unit, not a
/// whole bulk operation.
///
/// The lock never fails an operation. If the archive folder cannot be opened
/// or locked, the work runs without it, exactly as it did before the lock
/// existed.
public enum ClipboardArchiveWriteLock {
    /// A held lock. Release it on the thread that acquired it.
    public final class Handle {
        private let descriptor: Int32
        private let key: String
        private var released = false

        fileprivate init(descriptor: Int32, key: String) {
            self.descriptor = descriptor
            self.key = key
        }

        public func release() {
            guard !released else {
                return
            }
            released = true
            ClipboardArchiveWriteLock.leave(key: key)
            if descriptor >= 0 {
                flock(descriptor, LOCK_UN)
                close(descriptor)
            }
        }

        deinit {
            // A handle dropped without `release()` must not keep the archive
            // locked for the life of the process.
            if !released, descriptor >= 0 {
                flock(descriptor, LOCK_UN)
                close(descriptor)
            }
        }
    }

    /// Runs `body` holding the lock. Safe to nest on one thread.
    public static func withLock<T>(archiveRoot: URL, _ body: () throws -> T) rethrows -> T {
        let handle = acquire(archiveRoot: archiveRoot)
        defer { handle.release() }
        return try body()
    }

    /// Takes the lock, waiting for any other holder. A thread that already
    /// holds it gets a handle at once, so a locked operation can call another
    /// locked operation without deadlocking itself.
    public static func acquire(archiveRoot: URL) -> Handle {
        let key = threadKey(for: archiveRoot)
        let depth = Thread.current.threadDictionary[key] as? Int ?? 0
        Thread.current.threadDictionary[key] = depth + 1
        guard depth == 0 else {
            return Handle(descriptor: -1, key: key)
        }

        // O_CLOEXEC: a helper process started while the lock is held must
        // not inherit the descriptor, or the lock would outlive this holder.
        let descriptor = open(archiveRoot.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard descriptor >= 0 else {
            return Handle(descriptor: -1, key: key)
        }
        while flock(descriptor, LOCK_EX) != 0 {
            if errno == EINTR {
                continue
            }
            close(descriptor)
            return Handle(descriptor: -1, key: key)
        }
        return Handle(descriptor: descriptor, key: key)
    }

    fileprivate static func leave(key: String) {
        let depth = Thread.current.threadDictionary[key] as? Int ?? 0
        if depth <= 1 {
            Thread.current.threadDictionary.removeObject(forKey: key)
        } else {
            Thread.current.threadDictionary[key] = depth - 1
        }
    }

    private static func threadKey(for archiveRoot: URL) -> String {
        "ClipboardArchiveWriteLock:" + archiveRoot.resolvingSymlinksInPath().path
    }
}
