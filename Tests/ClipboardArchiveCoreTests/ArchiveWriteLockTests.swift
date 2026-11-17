import Foundation
import Testing
@testable import ClipboardArchiveCore

/// A capture appended while a day file is being rewritten must not be lost.
/// The append and every read-then-replace of a day file take one lock.
@Suite("Archive write lock")
struct ArchiveWriteLockTests {
    private final class Flag: @unchecked Sendable {
        private let lock = NSLock()
        private var value = false
        func set() { lock.lock(); value = true; lock.unlock() }
        var isSet: Bool { lock.lock(); defer { lock.unlock() }; return value }
    }

    private func scratch(_ label: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("clipboard-write-lock-\(label)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func capture(_ content: String) -> ClipboardCapture {
        ClipboardCapture(
            content: content,
            sourceApp: ClipboardSourceApp(name: "Notes", bundleIdentifier: "com.apple.Notes"),
            pasteboardTypes: ["public.utf8-plain-text"]
        )
    }

    @Test func aCaptureWaitsForTheHolderAndThenLands() throws {
        let root = try scratch("wait")
        defer { try? FileManager.default.removeItem(at: root) }
        let writer = ClipboardArchiveWriter(archiveRoot: root)
        try writer.archiveAllowedCapture(capture("seed so the archive exists"))

        let held = ClipboardArchiveWriteLock.acquire(archiveRoot: root)
        let finished = Flag()
        let done = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            _ = try? writer.archiveAllowedCapture(self.capture("copied while a rewrite holds the lock"))
            finished.set()
            done.signal()
        }
        // Long enough for an unlocked append to have finished many times over.
        Thread.sleep(forTimeInterval: 0.4)
        #expect(!finished.isSet)

        held.release()
        #expect(done.wait(timeout: .now() + 5) == .success)
        let stored = try ClipboardArchiveReader(archiveRoot: root).recentItems(since: .distantPast, limit: 10)
        #expect(stored.contains { $0.contentPreview == "copied while a rewrite holds the lock" })
    }

    @Test func theLockNestsOnOneThread() throws {
        let root = try scratch("nest")
        defer { try? FileManager.default.removeItem(at: root) }
        let writer = ClipboardArchiveWriter(archiveRoot: root)
        try writer.archiveAllowedCapture(capture("seed"))

        // An operation holding the lock appends through the writer, which
        // takes the lock again. That must not deadlock.
        let outer = ClipboardArchiveWriteLock.acquire(archiveRoot: root)
        let inner = ClipboardArchiveWriteLock.acquire(archiveRoot: root)
        try writer.archiveAllowedCapture(capture("appended while already holding the lock"))
        inner.release()
        outer.release()
        // And it is fully released afterwards: another thread gets it at once.
        let done = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            let handle = ClipboardArchiveWriteLock.acquire(archiveRoot: root)
            handle.release()
            done.signal()
        }
        #expect(done.wait(timeout: .now() + 5) == .success)
    }

    @Test func aMissingArchiveFolderNeverBlocksOrFails() throws {
        let root = try scratch("missing").appendingPathComponent("not-created-yet")
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
        let answer: Int = ClipboardArchiveWriteLock.withLock(archiveRoot: root) { () -> Int in 7 }
        #expect(answer == 7)
        // The first capture creates the archive and still lands.
        try ClipboardArchiveWriter(archiveRoot: root).archiveAllowedCapture(capture("first clip ever"))
        #expect(try ClipboardArchiveReader(archiveRoot: root).recentItems(since: .distantPast, limit: 5).count == 1)
    }

    /// The command-line tool and the app are different processes. A lock
    /// that only held between threads would leave `prune` racing the app.
    @Test func anotherProcessHoldingTheLockIsWaitedFor() throws {
        let root = try scratch("process")
        defer { try? FileManager.default.removeItem(at: root) }
        try ClipboardArchiveWriter(archiveRoot: root).archiveAllowedCapture(capture("seed"))

        let holder = Process()
        holder.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        holder.arguments = ["-c", """
        import fcntl, os, sys, time
        fd = os.open(sys.argv[1], os.O_RDONLY)
        fcntl.flock(fd, fcntl.LOCK_EX)
        print("held", flush=True)
        time.sleep(1.0)
        """, root.path]
        let output = Pipe()
        holder.standardOutput = output
        try holder.run()
        defer { holder.terminate() }
        // Blocks until the other process says it holds the lock.
        #expect(String(data: output.fileHandleForReading.availableData, encoding: .utf8)?.contains("held") == true)

        let started = Date()
        ClipboardArchiveWriteLock.acquire(archiveRoot: root).release()
        let waited = Date().timeIntervalSince(started)
        #expect(waited > 0.5, "the lock was taken while another process held it (waited \\(waited)s)")
        holder.waitUntilExit()
    }

    /// The failure this lock exists for, driven hard: one thread captures
    /// while another keeps rewriting the same day file. Every capture has to
    /// still be there at the end.
    @Test func noCaptureIsLostWhileTheDayFileIsBeingRewritten() throws {
        let root = try scratch("stress")
        let indexFolder = try scratch("stress-index")
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: indexFolder)
        }
        let writer = ClipboardArchiveWriter(archiveRoot: root)
        let engine = ClipboardBulkEngine(
            archiveRoot: root,
            indexURL: indexFolder.appendingPathComponent("index.sqlite")
        )
        // Clips to delete one at a time, each delete rewriting today's file.
        // Padded so the file is large enough for a rewrite to take a while.
        let padding = String(repeating: "x", count: 600)
        var victims: [String] = []
        for number in 0..<120 {
            victims.append(try writer.archiveAllowedCapture(capture("victim \(number) \(padding)")).id)
        }

        let captures = 300
        let group = DispatchGroup()
        let failed = Flag()
        DispatchQueue.global().async(group: group) {
            for id in victims {
                if (try? engine.execute(ClipboardBulkCriteria(eventIDs: [id]))) == nil {
                    failed.set()
                }
            }
        }
        DispatchQueue.global().async(group: group) {
            for number in 0..<captures {
                if (try? writer.archiveAllowedCapture(self.capture("stress-capture-\(number)"))) == nil {
                    failed.set()
                }
            }
        }
        #expect(group.wait(timeout: .now() + 120) == .success)
        #expect(!failed.isSet)

        let stored = try ClipboardArchiveReader(archiveRoot: root).recentItems(since: .distantPast, limit: 10_000)
        let kept = Set(stored.map(\.contentPreview).filter { $0.hasPrefix("stress-capture-") })
        #expect(kept.count == captures, "lost \(captures - kept.count) of \(captures) captures")
        #expect(!stored.contains { $0.contentPreview.hasPrefix("victim ") })
    }
}
