import Darwin
import Foundation
import Testing
@testable import ClipboardArchiveCore

@Suite("Content-free usage logging")
struct ClipboardUsageLogTests {
    private func root() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("usage-test-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    @Test func rotationPrivacyAndPermissions() throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        let log = ClipboardUsageLog(archiveRoot: root, maximumFileBytes: 1024, retainedFiles: 3)
        for _ in 0..<100 { #expect(log.record(.search, outcome: .hit, scope: .thisWindow, count: 2)) }
        let files = try FileManager.default.contentsOfDirectory(at: log.directory, includingPropertiesForKeys: nil).filter { $0.pathExtension == "ndjson" }
        #expect(files.count == 3)
        for file in files {
            let data = try Data(contentsOf: file)
            #expect(data.count <= 1024)
            let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
            #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
            for line in data.split(separator: 10) {
                let row = try #require(JSONSerialization.jsonObject(with: Data(line)) as? [String: Any])
                #expect(Set(row.keys) == Set(["schema", "timestamp", "version", "build", "event", "outcome", "scope", "count", "durationMs", "bytes"]))
                #expect(row["event"] as? String == "search")
            }
        }
        let attributes = try FileManager.default.attributesOfItem(atPath: log.directory.path)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o700)
    }

    @Test func symlinksAndBusyLockFailWithoutTouchingTarget() throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        let log = ClipboardUsageLog(archiveRoot: root)
        #expect(log.record(.appStart))
        let target = root.appendingPathComponent("preserve")
        let marker = Data("PRIVATE_CLIPBOARD_MARKER".utf8)
        try marker.write(to: target)
        let current = log.directory.appendingPathComponent("events.ndjson")
        try FileManager.default.removeItem(at: current)
        try FileManager.default.createSymbolicLink(at: current, withDestinationURL: target)
        #expect(!log.record(.copyBack))
        #expect(try Data(contentsOf: target) == marker)
        try FileManager.default.removeItem(at: current)
        let fd = open(log.directory.appendingPathComponent(".lock").path, O_RDWR)
        defer { close(fd) }
        #expect(flock(fd, LOCK_EX | LOCK_NB) == 0)
        #expect(!log.record(.capture))
        #expect(flock(fd, LOCK_UN) == 0)
        #expect(log.record(.capture))
    }

    @Test func ingestAndRebuildEmitOutcomesWithoutMarker() throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        let index = ClipboardDerivedIndex(archiveRoot: root, indexURL: root.appendingPathComponent("index.sqlite"))
        let ingestor = ClipboardIngestor(archiveWriter: ClipboardArchiveWriter(archiveRoot: root), derivedIndex: index)
        let marker = "USAGE_PRIVACY_PLANTED_MARKER"
        _ = try ingestor.ingest(ClipboardCapture(content: marker, sourceApp: ClipboardSourceApp(name: "Synthetic")))
        _ = try ingestor.ingest(ClipboardCapture(content: "password=synthetic-credential-fixture", sourceApp: ClipboardSourceApp(name: "1Password", bundleIdentifier: "com.1password.1password")))
        _ = try index.rebuild()
        let broken = ClipboardDerivedIndex(archiveRoot: root, indexURL: root.appendingPathComponent("broken.sqlite"), sqliteExecutableURL: URL(fileURLWithPath: "/usr/bin/false"))
        _ = try ClipboardIngestor(archiveWriter: ClipboardArchiveWriter(archiveRoot: root), derivedIndex: broken).ingest(ClipboardCapture(content: "another safe fixture", sourceApp: ClipboardSourceApp(name: "Synthetic")))
        let content = try String(contentsOf: root.appendingPathComponent("usage/events.ndjson"))
        #expect(!content.contains(marker))
        for event in ["capture", "blocked", "index_rebuild", "error"] {
            #expect(content.contains("\"event\":\"\(event)\""))
        }
        #expect(content.contains("\"outcome\":\"failed\""))
    }
}
