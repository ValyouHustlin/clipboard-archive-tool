import Darwin
import Foundation

/// The bulk loader owns a process group from spawn (no parent/child setpgid
/// race). Its deadline is monotonic; timeout kills that group and reaps the
/// direct child before returning. File-backed stdin/output cannot deadlock on
/// a full pipe or a descendant that inherited a pipe descriptor.
enum ClipboardSQLiteProcess {
    static func run(executable: URL, database: URL, input: URL, timeout: TimeInterval) throws {
        var actions: posix_spawn_file_actions_t?
        var attributes: posix_spawnattr_t?
        guard posix_spawn_file_actions_init(&actions) == 0,
              posix_spawnattr_init(&attributes) == 0 else { throw POSIXError(.ENOMEM) }
        defer {
            posix_spawn_file_actions_destroy(&actions)
            posix_spawnattr_destroy(&attributes)
        }
        // CHECKED, because the whole timeout path is built on them. If
        // SETPGROUP silently failed the child would stay in OUR group, and then
        // `kill(-pid, ...)` below names a group that is not the child's: the
        // signal goes nowhere (ESRCH) and the reap that follows it waits for a
        // process nobody killed. An unchecked addopen is the same shape one
        // level down — a failed stdin redirect leaves the child inheriting the
        // PARENT's stdin, so `clipboard-archive repair-index` run from a
        // terminal would feed the operator's keystrokes to sqlite3 as SQL.
        // Refusing to spawn is the only safe answer to either.
        // THE CHILD STARTS FROM A CLEAN SIGNAL SLATE, and this is not
        // housekeeping. A signal MASK is inherited across exec, and an IGNORED
        // disposition is too — only installed handlers reset. This app is a
        // Cocoa/dispatch process, and a runtime that blocks or ignores a signal
        // hands that state straight to sqlite3: measured here, a parent that
        // blocks SIGTERM spawns a child for which `kill -TERM` is a silent
        // no-op that exits 0. SIGKILL cannot be blocked, so the timeout path
        // still works, but "the child inherited a disposition nobody chose" is
        // exactly the unkillable-child shape the bounded reap below exists for,
        // and it is cheaper to prevent than to survive.
        var defaultedSignals = sigset_t()
        sigfillset(&defaultedSignals)
        var clearMask = sigset_t()
        sigemptyset(&clearMask)
        guard posix_spawnattr_setflags(&attributes,
                  Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK)) == 0,
              posix_spawnattr_setpgroup(&attributes, 0) == 0,
              posix_spawnattr_setsigdefault(&attributes, &defaultedSignals) == 0,
              posix_spawnattr_setsigmask(&attributes, &clearMask) == 0,
              posix_spawn_file_actions_addopen(&actions, STDIN_FILENO, input.path, O_RDONLY, 0) == 0,
              posix_spawn_file_actions_addopen(&actions, STDOUT_FILENO, "/dev/null", O_WRONLY, 0) == 0,
              posix_spawn_file_actions_addopen(&actions, STDERR_FILENO, "/dev/null", O_WRONLY, 0) == 0
        else { throw POSIXError(.EINVAL) }
        let arguments: [UnsafeMutablePointer<CChar>?] = [executable.path, database.path].map { $0.withCString { strdup($0) } }
        let environment: [UnsafeMutablePointer<CChar>?] = ProcessInfo.processInfo.environment.map { key, value in
            "\(key)=\(value)".withCString { strdup($0) }
        }
        defer { (arguments + environment).forEach { free($0) } }
        guard (arguments + environment).allSatisfy({ $0 != nil }) else { throw POSIXError(.ENOMEM) }
        var envp = environment + [nil]
        var argv = arguments + [nil]
        var pid: pid_t = 0
        let spawned = posix_spawn(&pid, executable.path, &actions, &attributes, &argv, &envp)
        guard spawned == 0 else { throw POSIXError(POSIXErrorCode(rawValue: spawned) ?? .EIO) }
        let deadline = ProcessInfo.processInfo.systemUptime + max(0.05, timeout)
        var status: Int32 = 0
        while true {
            let waited = waitpid(pid, &status, WNOHANG)
            if waited == pid {
                // A stub/tool that exits after spawning a background child
                // must not leak that child beyond the operation either.
                // Killed AFTER the reap on purpose, and it cannot be reordered:
                // there is no way to learn the leader exited without reaping it.
                // An empty group makes this a harmless ESRCH; a non-empty one is
                // exactly the group we mean, because a pgid lives as long as any
                // member does.
                kill(-pid, SIGKILL)
                // `status` is a WAIT STATUS, not an exit code. Handing it to
                // `sqliteFailed` renders an exit(1) as "sqlite3 failed with
                // status 256", in an error type whose every other site carries a
                // real SQLite result code.
                guard exitedCleanly(status) else {
                    throw ClipboardDerivedIndexError.sqliteFailed(exitCode(status))
                }
                return
            }
            if waited < 0 && errno != EINTR { throw POSIXError(.ECHILD) }
            if ProcessInfo.processInfo.systemUptime >= deadline {
                kill(-pid, SIGKILL)
                // BOUNDED. An unbounded blocking reap assumes the kill landed and
                // that the child is killable; a child wedged in an uninterruptible
                // kernel wait is neither, and waiting forever here would hang the
                // rebuild queue — and so every future rebuild — for the life of
                // the process. Reap what we can, then give up and report the
                // timeout we already know happened. A child we failed to reap is
                // a zombie until this process exits, which is a leak we can see;
                // a hung rebuild queue is one we cannot.
                reapBounded(pid, &status)
                throw POSIXError(.ETIMEDOUT)
            }
            usleep(10_000)
        }
    }

    /// True when the child ran to completion and exited zero. A child killed by
    /// a signal did not "succeed with status 9".
    private static func exitedCleanly(_ status: Int32) -> Bool {
        (status & 0x7F) == 0 && ((status >> 8) & 0xFF) == 0
    }

    /// The child's own exit code, or the negated signal that killed it, so the
    /// two cases stay distinguishable in the error.
    private static func exitCode(_ status: Int32) -> Int32 {
        let signal = status & 0x7F
        return signal == 0 ? (status >> 8) & 0xFF : -signal
    }

    /// Reap `pid` for at most `limit` seconds. Never blocks forever.
    private static func reapBounded(_ pid: pid_t, _ status: inout Int32, limit: TimeInterval = 2) {
        let deadline = ProcessInfo.processInfo.systemUptime + limit
        while ProcessInfo.processInfo.systemUptime < deadline {
            let waited = waitpid(pid, &status, WNOHANG)
            if waited == pid { return }
            if waited < 0 && errno != EINTR { return }
            usleep(5_000)
        }
    }
}
