import Darwin
import Foundation

/// Content-free unresolved failures, independent of the rotating log sink.
/// A successful capture clears only archive/capture failures; an index repair
/// clears only index failures. Deleting or rotating logs cannot clear these.
struct ClipboardFailureState {
    let logDirectory: URL
    var url: URL { logDirectory.deletingLastPathComponent().appendingPathComponent("ClipboardArchive-operational-state.json") }

    func read() -> [String: Date]? {
        guard FileManager.default.fileExists(atPath: url.path) else { return [:] }
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode([String: Date].self, from: data)
    }

    @discardableResult
    func update(add: String? = nil, remove: [String] = []) -> Bool {
        let parent = url.deletingLastPathComponent()
        do { try ClipboardPrivateFileSystem.createDirectory(parent, archiveRoot: parent) } catch { return false }
        let fd = open(url.path + ".lock", O_CREAT | O_RDWR | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        let deadline = ProcessInfo.processInfo.systemUptime + 0.25
        while flock(fd, LOCK_EX | LOCK_NB) != 0 {
            guard errno == EWOULDBLOCK, ProcessInfo.processInfo.systemUptime < deadline else { return false }
            usleep(1_000)
        }
        defer { flock(fd, LOCK_UN) }
        var state: [String: Date]
        if let current = read() {
            state = current
        } else {
            // Undecodable state, and the two operations get opposite answers
            // because they carry opposite risk.
            //
            // REMOVE stays refused. Clearing failures we cannot read would let
            // an unrelated success erase evidence, which is the invariant the
            // original guard was written for and it is still right.
            //
            // ADD is now allowed, after setting the bad bytes aside once.
            // Refusing it was the defect: `read()` never recovers on its own, so
            // every later failure went unrecorded for the life of the machine
            // while `status` warned `failure_state_unreadable` forever with no
            // remedy. Recording a new failure is strictly MORE information than
            // an unreadable file, never less, so it cannot be the operation that
            // loses evidence.
            guard add != nil else { return false }
            quarantineUnreadableState()
            state = [:]
        }
        for code in remove { state.removeValue(forKey: code) }
        if let add { state[add] = ClipboardRuntime.now }
        do {
            try JSONEncoder().encode(state).writeClipboardAtomically(to: url)
            try ClipboardPrivateFileSystem.secureFile(url)
            return true
        } catch { return false }
    }

    /// Moves undecodable state to `...-operational-state.json.corrupt-<utc>` so
    /// it can be looked at, exactly once. An existing quarantine is never
    /// overwritten, and a quarantine that cannot be written must not stop the
    /// failure we are here to record from being recorded.
    private func quarantineUnreadableState() {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        let destination = URL(fileURLWithPath: url.path + ".corrupt-"
            + formatter.string(from: ClipboardRuntime.now))
        guard !FileManager.default.fileExists(atPath: destination.path) else { return }
        try? FileManager.default.moveItem(at: url, to: destination)
        try? ClipboardPrivateFileSystem.secureFile(destination)
    }
}

extension ClipboardOperationalLog {
    public var unresolvedFailures: [String] {
        guard let state = ClipboardFailureState(logDirectory: directory).read() else { return ["failure_state_unreadable"] }
        return state.keys.sorted()
    }

    public func recoverCaptureFailure() {
        let codes = ["capture_failed", "archive_append_failed"]
        guard !Set(unresolvedFailures).isDisjoint(with: codes) else { return }
        record(.captureRecovered)
    }

    public func recoverIndexUpsertFailure() {
        guard unresolvedFailures.contains("index_upsert_failed") else { return }
        _ = ClipboardFailureState(logDirectory: directory).update(remove: ["index_upsert_failed"])
    }

    public var sinkReadable: Bool {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory) else { return true }
        guard isDirectory.boolValue else { return false }
        guard FileManager.default.isReadableFile(atPath: directory.path),
              FileManager.default.isWritableFile(atPath: directory.path) else { return false }
        let primary = directory.appendingPathComponent(Self.fileBaseName + ".ndjson")
        if let attributes = try? FileManager.default.attributesOfItem(atPath: primary.path) {
            guard attributes[.type] as? FileAttributeType == .typeRegular,
                  FileManager.default.isReadableFile(atPath: primary.path),
                  FileManager.default.isWritableFile(atPath: primary.path) else { return false }
        }
        return true
    }
}
