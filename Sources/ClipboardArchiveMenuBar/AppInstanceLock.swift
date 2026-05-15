import Darwin
import ClipboardArchiveCore
import Foundation

final class AppInstanceLock {
    private var fileDescriptor: Int32 = -1

    func acquire() -> Bool {
        let lockURL = ClipboardDefaults.lockURL()
        try? FileManager.default.createDirectory(at: lockURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let lockPath = lockURL.path

        fileDescriptor = open(lockPath, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        guard fileDescriptor >= 0 else {
            return false
        }

        if flock(fileDescriptor, LOCK_EX | LOCK_NB) != 0 {
            close(fileDescriptor)
            fileDescriptor = -1
            return false
        }

        ftruncate(fileDescriptor, 0)
        let pid = "\(getpid())\n"
        _ = pid.withCString { write(fileDescriptor, $0, strlen($0)) }
        return true
    }

    deinit {
        if fileDescriptor >= 0 {
            flock(fileDescriptor, LOCK_UN)
            close(fileDescriptor)
        }
    }
}
