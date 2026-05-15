import Foundation

public struct ClipboardDerivedIndex: Sendable {
    public var archiveRoot: URL
    public var indexURL: URL

    public init(
        archiveRoot: URL,
        indexURL: URL = ClipboardDefaults.indexURL()
    ) {
        self.archiveRoot = archiveRoot
        self.indexURL = indexURL
    }

    public func rebuild() throws -> Int {
        try FileManager.default.createDirectory(at: indexURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        if FileManager.default.fileExists(atPath: indexURL.path) {
            try FileManager.default.removeItem(at: indexURL)
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["sqlite3", indexURL.path]
        let input = Pipe()
        let output = Pipe()
        let error = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = error
        try process.run()

        func writeSQL(_ sql: String) throws {
            try input.fileHandleForWriting.write(contentsOf: Data(sql.utf8))
        }

        try writeSQL("""
        PRAGMA journal_mode=OFF;
        PRAGMA synchronous=OFF;
        CREATE VIRTUAL TABLE clipboard_fts USING fts5(id UNINDEXED, captured_at UNINDEXED, source_app, content_type, preview, body);
        CREATE TABLE clipboard_meta(id TEXT PRIMARY KEY, captured_at TEXT, source_app TEXT, bundle_id TEXT, content_type TEXT, byte_count INTEGER, raw_content_path TEXT);
        BEGIN TRANSACTION;
        """)

        let reader = ClipboardArchiveReader(archiveRoot: archiveRoot)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let deleted = try ClipboardDeletionLedger(archiveRoot: archiveRoot).deletedIDs()
        var count = 0

        for fileURL in try reader.eventFiles() {
            let lines = try String(contentsOf: fileURL).split(separator: "\n", omittingEmptySubsequences: true)
            for line in lines {
                guard let data = String(line).data(using: .utf8),
                      let event = try? decoder.decode(StoredClipboardEvent.self, from: data),
                      event.privacyLabel != .doNotIndex,
                      !deleted.contains(event.id) else {
                    continue
                }
                let body = (try? reader.content(for: event)) ?? event.contentPreview
                try writeSQL("""

                INSERT INTO clipboard_fts(id,captured_at,source_app,content_type,preview,body) VALUES('\(escape(event.id))','\(escape(iso(event.capturedAt)))','\(escape(event.sourceApp.name))','\(escape(event.contentType.rawValue))','\(escape(event.contentPreview))','\(escape(body))');
                INSERT INTO clipboard_meta(id,captured_at,source_app,bundle_id,content_type,byte_count,raw_content_path) VALUES('\(escape(event.id))','\(escape(iso(event.capturedAt)))','\(escape(event.sourceApp.name))','\(escape(event.sourceApp.bundleIdentifier ?? ""))','\(escape(event.contentType.rawValue))',\(event.byteCount),'\(escape(event.rawContentPath ?? ""))');
                """)
                count += 1
            }
        }

        try writeSQL("\nCOMMIT;\n")
        try input.fileHandleForWriting.close()
        process.waitUntilExit()
        if process.terminationStatus != 0 {
            throw ClipboardDerivedIndexError.sqliteFailed(process.terminationStatus)
        }
        return count
    }

    public func search(_ query: String, limit: Int = 25) throws -> String {
        let sql = """
        SELECT captured_at || ' ' || id || ' ' || source_app || char(10) || snippet(clipboard_fts, 5, '[', ']', ' ... ', 24)
        FROM clipboard_fts
        WHERE clipboard_fts MATCH '\(escapeFTS(query))'
        ORDER BY captured_at DESC
        LIMIT \(limit);
        """

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["sqlite3", "-noheader", "-separator", "\n---\n", indexURL.path, sql]
        let output = Pipe()
        process.standardOutput = output
        try process.run()
        process.waitUntilExit()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8) ?? ""
    }

    @discardableResult
    public func delete(eventID: String) throws -> Bool {
        guard FileManager.default.fileExists(atPath: indexURL.path) else {
            return false
        }

        let sql = """
        DELETE FROM clipboard_fts WHERE id = '\(escape(eventID))';
        DELETE FROM clipboard_meta WHERE id = '\(escape(eventID))';
        """

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["sqlite3", indexURL.path, sql]
        try process.run()
        process.waitUntilExit()
        if process.terminationStatus != 0 {
            throw ClipboardDerivedIndexError.sqliteFailed(process.terminationStatus)
        }
        return true
    }

    private func escape(_ value: String) -> String {
        value.replacingOccurrences(of: "'", with: "''")
    }

    private func escapeFTS(_ value: String) -> String {
        "\"\(value.replacingOccurrences(of: "\"", with: "\"\""))\""
    }

    private func iso(_ date: Date) -> String {
        ISO8601DateFormatter().string(from: date)
    }
}

public enum ClipboardDerivedIndexError: Error, Equatable, CustomStringConvertible, Sendable {
    case sqliteFailed(Int32)

    public var description: String {
        switch self {
        case let .sqliteFailed(status):
            return "sqlite3 failed with status \(status)"
        }
    }
}
