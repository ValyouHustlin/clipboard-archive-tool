import Darwin
import ClipboardArchiveCore
import Foundation

final class AppInstanceLock {
    private var fileDescriptor: Int32 = -1

    func acquire() -> Bool {
        let lockURL = ClipboardDefaults.lockURL()
        let lockDirectory = lockURL.deletingLastPathComponent()
        let lockDirectoryAlreadyExisted = FileManager.default.fileExists(atPath: lockDirectory.path)
        try? FileManager.default.createDirectory(at: lockDirectory, withIntermediateDirectories: true)
        if !lockDirectoryAlreadyExisted {
            try? FileManager.default.setAttributes(
                [.posixPermissions: NSNumber(value: Int16(0o700))],
                ofItemAtPath: lockDirectory.path
            )
        }
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

        _ = fchmod(fileDescriptor, S_IRUSR | S_IWUSR)
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
