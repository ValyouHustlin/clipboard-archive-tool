import Foundation
import Testing
@testable import ClipboardArchiveCore

/// An archive root reached through a symlink (the installed default
/// `Archive/clipboard-history` is one) must read exactly like the real
/// directory: same event files, same recent items, same health numbers,
/// same search results. The root is resolved ONCE before every containment
/// test; per-file symlinks inside the archive are still excluded, and body
/// paths that escape the root are still rejected.
@Suite("Symlinked archive root")
struct SymlinkedArchiveRootTests {
    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("clipboard-symlink-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func seedArchive(at root: URL, count: Int = 3) throws {
        let writer = ClipboardArchiveWriter(archiveRoot: root)
        for index in 0..<count {
            _ = try writer.archiveAllowedCapture(
                ClipboardCapture(
                    capturedAt: Date(timeIntervalSince1970: 1_800_000_000 + Double(index)),
                    content: "symlink fixture note \(index) needle-token",
                    sourceApp: ClipboardSourceApp(name: "Synthetic"),
                    pasteboardTypes: ["public.utf8-plain-text"]
                )
            )
        }
    }

    private func relativeNames(_ urls: [URL]) -> [String] {
        urls.map { $0.lastPathComponent }.sorted()
    }

    @Test("A symlinked root reads identically to the real directory")
    func symlinkedRootMatchesRealRoot() throws {
        let base = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: base) }
        let real = base.appendingPathComponent("real-archive", isDirectory: true)
        try FileManager.default.createDirectory(at: real, withIntermediateDirectories: true)
        try seedArchive(at: real)

        let link = base.appendingPathComponent("linked-archive", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)

        let realFiles = try ClipboardArchiveReader(archiveRoot: real).eventFiles()
        let linkFiles = try ClipboardArchiveReader(archiveRoot: link).eventFiles()
        #expect(!realFiles.isEmpty)
        #expect(relativeNames(linkFiles) == relativeNames(realFiles))

        let realItems = try ClipboardArchiveReader(archiveRoot: real)
            .recentItems(since: .distantPast, limit: 50)
        let linkItems = try ClipboardArchiveReader(archiveRoot: link)
            .recentItems(since: .distantPast, limit: 50)
        #expect(realItems.count == 3)
        #expect(linkItems.map(\.id) == realItems.map(\.id))

        let indexURL = base.appendingPathComponent("index.sqlite")
        let realHealth = try ClipboardArchiveHealthReporter(archiveRoot: real, indexURL: indexURL).health()
        let linkHealth = try ClipboardArchiveHealthReporter(archiveRoot: link, indexURL: indexURL).health()
        #expect(realHealth.storedEvents == 3)
        #expect(linkHealth.storedEvents == realHealth.storedEvents)
        #expect(realHealth.archiveBytes > 0)
        #expect(linkHealth.archiveBytes == realHealth.archiveBytes)
        #expect(linkHealth.eventFileCount == realHealth.eventFileCount)

        let options = ClipboardSearchOptions(query: "needle-token", limit: 25)
        let realHits = try ClipboardArchiveSearcher(archiveRoot: real).search(options)
        let linkHits = try ClipboardArchiveSearcher(archiveRoot: link).search(options)
        #expect(realHits.count == 3)
        #expect(linkHits.map(\.event.id) == realHits.map(\.event.id))
    }

    @Test("/private/tmp and /tmp spellings of one root agree")
    func privateTmpAndTmpRootsAgree() throws {
        let name = "clipboard-symlink-tests-\(UUID().uuidString)"
        let privateRoot = URL(fileURLWithPath: "/private/tmp").appendingPathComponent(name, isDirectory: true)
        let tmpRoot = URL(fileURLWithPath: "/tmp").appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: privateRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: privateRoot) }
        try seedArchive(at: privateRoot, count: 2)

        let privateFiles = try ClipboardArchiveReader(archiveRoot: privateRoot).eventFiles()
        let tmpFiles = try ClipboardArchiveReader(archiveRoot: tmpRoot).eventFiles()
        #expect(!privateFiles.isEmpty)
        #expect(relativeNames(tmpFiles) == relativeNames(privateFiles))

        let indexURL = privateRoot.appendingPathComponent("index.sqlite")
        let privateHealth = try ClipboardArchiveHealthReporter(archiveRoot: privateRoot, indexURL: indexURL).health()
        let tmpHealth = try ClipboardArchiveHealthReporter(archiveRoot: tmpRoot, indexURL: indexURL).health()
        #expect(privateHealth.storedEvents == 2)
        #expect(tmpHealth.storedEvents == privateHealth.storedEvents)
        #expect(tmpHealth.archiveBytes == privateHealth.archiveBytes)
    }

    @Test("A traversal body path is still rejected")
    func traversalBodyPathStillRejected() throws {
        let base = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: base) }
        let real = base.appendingPathComponent("real-archive", isDirectory: true)
        try FileManager.default.createDirectory(at: real, withIntermediateDirectories: true)
        let link = base.appendingPathComponent("linked-archive", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)

        for root in [real, link] {
            #expect(throws: ClipboardArchivePathError.self) {
                _ = try ClipboardArchivePath.containedURL(
                    relativePath: "../outside.txt",
                    archiveRoot: root
                )
            }
        }
    }

    @Test("A symlinked day file inside raw/ is still excluded")
    func symlinkedDayFileInsideRawExcluded() throws {
        let base = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: base) }
        let real = base.appendingPathComponent("real-archive", isDirectory: true)
        try FileManager.default.createDirectory(at: real, withIntermediateDirectories: true)
        try seedArchive(at: real, count: 1)

        let outside = base.appendingPathComponent("2020-01-01_clipboard-events.ndjson")
        try Data("{}\n".utf8).write(to: outside)
        let dayDirectory = real
            .appendingPathComponent("raw", isDirectory: true)
            .appendingPathComponent("2020", isDirectory: true)
        try FileManager.default.createDirectory(at: dayDirectory, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: dayDirectory.appendingPathComponent("2020-01-01_clipboard-events.ndjson"),
            withDestinationURL: outside
        )

        let link = base.appendingPathComponent("linked-archive", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)

        for root in [real, link] {
            let files = try ClipboardArchiveReader(archiveRoot: root).eventFiles()
            #expect(files.count == 1)
            #expect(!files.contains { $0.lastPathComponent == "2020-01-01_clipboard-events.ndjson" })
        }
    }
}
