import Darwin
import Foundation

/// Content-free, local diagnostics. The API deliberately accepts no free-form
/// strings, event IDs, hashes, queries, app names, paths or Error values.
public struct ClipboardUsageLog: Sendable {
    public enum Event: String, Codable, Sendable {
        case appStart = "app_start", search, quickPicker = "quick_picker"
        case copyBack = "copy_back", capture, blocked
        case indexRebuild = "index_rebuild", error
    }

    public enum Outcome: String, Codable, Sendable {
        case success, hit, miss, failed, excluded, unavailable
    }

    public enum Scope: String, Codable, Sendable {
        case application, allHistory = "all_history", thisWindow = "this_window"
        case quickPicker = "quick_picker", archive, index
    }

    private struct Row: Encodable {
        let schema = 1
        let timestamp: Date
        let version: [Int]
        let build: Int
        let event: Event
        let outcome: Outcome
        let scope: Scope
        let count: Int
        let durationMs: Double
        let bytes: Int
    }

    public let directory: URL
    public let maximumFileBytes: Int
    public let retainedFiles: Int

    public init(archiveRoot: URL, maximumFileBytes: Int = 1_048_576, retainedFiles: Int = 5) {
        directory = archiveRoot.appendingPathComponent("usage", isDirectory: true)
        self.maximumFileBytes = max(512, maximumFileBytes)
        self.retainedFiles = max(1, min(10, retainedFiles))
    }

    public var file: ClipboardRotatingLogFile {
        ClipboardRotatingLogFile(
            directory: directory,
            baseName: "events",
            maximumFileBytes: maximumFileBytes,
            retainedFiles: retainedFiles
        )
    }

    /// Best effort: a busy log or disk error cannot interrupt a copy/capture.
    /// One nonblocking cross-process lock covers size-check, rotation and
    /// append — all of it in the shared rotating appender.
    @discardableResult
    public func record(
        _ event: Event, outcome: Outcome = .success, scope: Scope = .application,
        count: Int = 1, durationMs: Double = 0, bytes: Int = 0
    ) -> Bool {
        let identity = ClipboardRotatingLogFile.bundleVersion()
        guard let data = try? ClipboardRotatingLogFile.rowEncoder().encode(Row(
            timestamp: Date(),
            version: identity.version,
            build: identity.build,
            event: event, outcome: outcome, scope: scope,
            count: max(0, count), durationMs: durationMs.isFinite ? max(0, durationMs) : 0,
            bytes: max(0, bytes)
        )) else {
            return false
        }
        return file.append(data)
    }
}
