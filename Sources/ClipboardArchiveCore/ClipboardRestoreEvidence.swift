import Darwin
import Foundation

public struct ClipboardRestoreEvidence: Codable, Sendable {
    public var verifiedAt: Date
    public var backupID: String
    public var storedEvents: Int
    public var archivePath: String
    public var archiveIdentity: String

    static func identity(_ root: URL) -> String? {
        var info = stat()
        guard stat(root.path, &info) == 0 else { return nil }
        return "\(info.st_dev):\(info.st_ino)"
    }
    public static func read(archiveRoot: URL, settingsURL: URL) -> ClipboardRestoreEvidence? {
        let url = settingsURL.deletingLastPathComponent().appendingPathComponent("restore-verification.json")
        guard let data = try? Data(contentsOf: url),
              let receipt = try? JSONDecoder().decode(Self.self, from: data),
              receipt.archivePath == archiveRoot.resolvingSymlinksInPath().path,
              receipt.archiveIdentity == identity(archiveRoot) else { return nil }
        return receipt
    }
    static func write(archiveRoot: URL, settingsURL: URL, backupID: String, storedEvents: Int) throws {
        guard let identity = identity(archiveRoot) else { throw CocoaError(.fileReadUnknown) }
        let receipt = Self(verifiedAt: ClipboardRuntime.now, backupID: backupID,
            storedEvents: storedEvents, archivePath: archiveRoot.resolvingSymlinksInPath().path,
            archiveIdentity: identity)
        let directory = settingsURL.deletingLastPathComponent()
        try ClipboardPrivateFileSystem.createDirectory(directory, archiveRoot: directory)
        let url = directory.appendingPathComponent("restore-verification.json")
        try JSONEncoder().encode(receipt).writeClipboardAtomically(to: url)
        try ClipboardPrivateFileSystem.secureFile(url)
    }
}
