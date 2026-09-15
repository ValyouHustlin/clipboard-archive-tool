import ClipboardArchiveCore
import Darwin
import Foundation

/// What the launch agent says, read from its property list and nothing else.
struct LaunchAgentFacts {
    var plistPath: String
    var present: Bool
    var programPath: String?
    var programExists: Bool
    /// The stores the plist pins, when it pins any.
    var archiveRoot: String?
    var indexPath: String?
    /// nil when the check was not run (a test pointing at a fixture plist
    /// has no business asking launchd about a real label).
    var loadedInLaunchd: Bool?

    /// Reads the plist at `path` without loading, starting or touching
    /// anything. The path comes from the caller so a test can point at a
    /// fixture instead of the real one.
    static func read(plistPath: String, askLaunchd: Bool) -> LaunchAgentFacts {
        var facts = LaunchAgentFacts(
            plistPath: plistPath,
            present: FileManager.default.fileExists(atPath: plistPath),
            programPath: nil,
            programExists: false,
            archiveRoot: nil,
            indexPath: nil,
            loadedInLaunchd: nil
        )
        guard facts.present,
              let data = FileManager.default.contents(atPath: plistPath),
              let plist = try? PropertyListSerialization.propertyList(
                  from: data, options: [], format: nil
              ) as? [String: Any] else {
            return facts
        }
        if let program = plist["Program"] as? String {
            facts.programPath = program
        } else if let arguments = plist["ProgramArguments"] as? [String], let first = arguments.first {
            // `/usr/bin/open <app>` names the app in the second argument;
            // the thing that has to exist is what would actually be run.
            facts.programPath = arguments.count > 1 && first.hasSuffix("/open") ? arguments[1] : first
        }
        facts.programExists = facts.programPath.map {
            FileManager.default.fileExists(atPath: $0)
        } ?? false
        if let environment = plist["EnvironmentVariables"] as? [String: String] {
            facts.archiveRoot = environment["CLIPBOARD_ARCHIVE_ARCHIVE_ROOT"]
            facts.indexPath = environment["CLIPBOARD_ARCHIVE_INDEX_PATH"]
        }
        if askLaunchd, let label = plist["Label"] as? String {
            facts.loadedInLaunchd = launchdResolves(label: label)
        }
        return facts
    }

    private static func launchdResolves(label: String) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = ["print", "gui/\(getuid())/\(label)"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return false
        }
        process.waitUntilExit()
        return process.terminationStatus == 0
    }
}

enum StatusCommand {
    static let plistPathEnvironmentKey = "CLIPBOARD_ARCHIVE_LAUNCH_AGENT_PLIST"

    static func defaultPlistPath(environment: [String: String] = ProcessInfo.processInfo.environment) -> String {
        if let override = environment[plistPathEnvironmentKey], !override.isEmpty {
            return override
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/app.clipboardarchive.plist")
            .path
    }

    /// The process holding the single-instance lock, if one is alive.
    ///
    /// The lock file is the only honest answer: launchd reports the exit of
    /// whatever it launched, which for an `open`-style agent is a launcher
    /// that exited successfully seconds after the app it started came up.
    static func lockHolder(lockURL: URL) -> (held: Bool, pid: Int32?) {
        let pid = (try? String(contentsOf: lockURL, encoding: .utf8))
            .flatMap { Int32($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
            .flatMap { $0 > 0 ? $0 : nil }
        let descriptor = open(lockURL.path, O_RDONLY)
        guard descriptor >= 0 else {
            return (false, nil)
        }
        defer { close(descriptor) }
        // Ask for the lock rather than asking after the pid in the file.
        // A pid outlives nothing — it is stale after a crash and can be
        // handed to an unrelated process — while the lock is released by
        // the kernel when its holder dies. Taking it shared and letting go
        // at once cannot keep a real instance out.
        if flock(descriptor, LOCK_SH | LOCK_NB) == 0 {
            flock(descriptor, LOCK_UN)
            return (false, pid)
        }
        return (errno == EWOULDBLOCK, pid)
    }

    struct Report {
        var facts: ClipboardStatusFacts
        var verdict: ClipboardStatusVerdict
        var lockPID: Int32?
        var capturesToday: Int
        var archiveBytes: Int64
        var diskFreeBytes: Int64
        var latestCapture: Date?
        var latestHeartbeat: Date?
        var pollsSinceLastHeartbeat: Int
        var launchAgent: LaunchAgentFacts
    }

    static func gather(_ options: CLIOptions, askLaunchd: Bool) throws -> Report {
        let resolution = options.storeResolution
        let storesPresent = FileManager.default.fileExists(atPath: options.archiveRoot.path)
        let lock = lockHolder(lockURL: resolution.lockURL)
        let settings = ClipboardSettingsStore(settingsURL: resolution.settingsURL).load()

        // Every retained row: a cap here would silently under-report the
        // error count on a busy log, which is the number most worth having.
        let operationalRows = options.operationalLog.read(limit: 0)
        let heartbeat = operationalRows.last { $0.code == "heartbeat" }
        let dayAgo = Date().addingTimeInterval(-86_400)
        let errorsLastDay = operationalRows.filter {
            $0.level == "error" && ($0.timestamp.map { $0 >= dayAgo } ?? false)
        }.count

        let latestCapture = newestCapture(options)
        let usage = try readUsageRows(archiveRoot: options.archiveRoot)
        // Today's bucket by name, not the last bucket that has rows: on a
        // quiet day the latter would report an older day's count under a
        // heading that says today.
        let todayKey = ClipboardUsageStats.dayKey(for: Date())
        let today = ClipboardUsageStats.summarize(usage: usage).days.first { $0.day == todayKey }

        let facts = ClipboardStatusFacts(
            storesPresent: storesPresent,
            appRunning: lock.held,
            captureEnabled: settings.archiveEnabled,
            heartbeatAge: heartbeat?.timestamp.map { Date().timeIntervalSince($0) },
            lastCaptureAge: latestCapture.map { Date().timeIntervalSince($0) },
            errorsLastDay: errorsLastDay,
            indexState: indexState(options),
            launchAgentProgramMissing: false,
            launchAgentStoresDiffer: false
        )

        var resolvedFacts = facts
        let agent = LaunchAgentFacts.read(
            plistPath: defaultPlistPath(),
            askLaunchd: askLaunchd
        )
        if agent.present {
            resolvedFacts.launchAgentProgramMissing = !agent.programExists
            let pinnedArchive = agent.archiveRoot.map { URL(fileURLWithPath: $0).standardizedFileURL.path }
            let pinnedIndex = agent.indexPath.map { URL(fileURLWithPath: $0).standardizedFileURL.path }
            resolvedFacts.launchAgentStoresDiffer =
                (pinnedArchive != nil && pinnedArchive != options.archiveRoot.standardizedFileURL.path)
                || (pinnedIndex != nil && pinnedIndex != options.indexPath.standardizedFileURL.path)
        }

        return Report(
            facts: resolvedFacts,
            verdict: ClipboardStatusRules.verdict(resolvedFacts),
            lockPID: lock.held ? lock.pid : nil,
            capturesToday: today?.captures ?? 0,
            archiveBytes: archiveBytes(options),
            diskFreeBytes: diskFree(options.archiveRoot),
            latestCapture: latestCapture,
            latestHeartbeat: heartbeat?.timestamp,
            pollsSinceLastHeartbeat: Int(heartbeat?.numbers["polls"] ?? 0),
            launchAgent: agent
        )
    }

    /// Newest capture time: one row from the index, falling back to the
    /// archive when there is no index to ask.
    private static func newestCapture(_ options: CLIOptions) -> Date? {
        let index = ClipboardDerivedIndex(archiveRoot: options.archiveRoot, indexURL: options.indexPath)
        if FileManager.default.fileExists(atPath: options.indexPath.path),
           let newest = try? index.browse(limit: 1).first {
            return newest.capturedAt
        }
        return try? ClipboardArchiveReader(archiveRoot: options.archiveRoot)
            .recentItems(since: .distantPast, limit: 1).first?.capturedAt
    }

    /// Fresh, stale or missing, decided by modification times rather than a
    /// full read: `status` promises to be fast.
    private static func indexState(_ options: CLIOptions) -> ClipboardStatusFacts.IndexState {
        let manager = FileManager.default
        guard manager.fileExists(atPath: options.indexPath.path) else {
            return .missing
        }
        let indexModified = (try? options.indexPath.resourceValues(forKeys: [.contentModificationDateKey]))?
            .contentModificationDate ?? .distantPast
        let files = (try? ClipboardArchiveReader(archiveRoot: options.archiveRoot).eventFiles()) ?? []
        let newestDayFile = files.compactMap {
            (try? $0.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        }.max() ?? .distantPast
        return indexModified >= newestDayFile ? .fresh : .stale
    }

    private static func archiveBytes(_ options: CLIOptions) -> Int64 {
        let files = (try? ClipboardArchiveReader(archiveRoot: options.archiveRoot).eventFiles()) ?? []
        return files.reduce(Int64(0)) { total, url in
            total + Int64((try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
        }
    }

    private static func diskFree(_ url: URL) -> Int64 {
        let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage ?? 0
    }

    /// Every usage row still on disk, newest file last.
    static func readUsageRows(archiveRoot: URL) throws -> [ClipboardUsageRow] {
        let log = ClipboardUsageLog(archiveRoot: archiveRoot)
        var rows: [ClipboardUsageRow] = []
        for url in log.file.files.reversed() {
            guard let data = try? Data(contentsOf: url) else {
                continue
            }
            for line in data.split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: true) {
                if let row = ClipboardUsageRow.decode(line: line) {
                    rows.append(row)
                }
            }
        }
        return rows
    }

    static func run(_ options: CLIOptions) throws -> ClipboardCLIExit {
        let report = try gather(options, askLaunchd: true)
        let facts = report.facts

        if options.json {
            CLIOutcome.printJSON([
                "schema": 1,
                "app_running": facts.appRunning,
                "pid": report.lockPID.map { Int($0) as Any } ?? NSNull(),
                "capture_enabled": facts.captureEnabled,
                "heartbeat_age_seconds": facts.heartbeatAge.map { Int($0) as Any } ?? NSNull(),
                "polls_last_heartbeat": report.pollsSinceLastHeartbeat,
                "last_capture_age_seconds": facts.lastCaptureAge.map { Int($0) as Any } ?? NSNull(),
                "captures_today": report.capturesToday,
                "errors_last_24h": facts.errorsLastDay,
                "index_state": facts.indexState.rawValue,
                "archive_bytes": report.archiveBytes,
                "disk_free_bytes": report.diskFreeBytes,
                "launch_agent": [
                    "plist_present": report.launchAgent.present,
                    "program_path": report.launchAgent.programPath as Any? ?? NSNull(),
                    "program_exists": report.launchAgent.programExists,
                    "loaded": report.launchAgent.loadedInLaunchd.map { $0 as Any } ?? NSNull(),
                    "stores_differ": facts.launchAgentStoresDiffer
                ],
                "warnings": report.verdict.warnings,
                "exit": report.verdict.exit.rawValue
            ])
            return report.verdict.exit
        }

        print("Clipboard Archive status")
        print("app_running: \(facts.appRunning)\(report.lockPID.map { " (pid \($0))" } ?? "")")
        print("capture_enabled: \(facts.captureEnabled)")
        print("heartbeat: \(facts.heartbeatAge.map { "\(ClipboardStatusRules.describe($0)) ago" } ?? "never")")
        print("last_capture: \(facts.lastCaptureAge.map { "\(ClipboardStatusRules.describe($0)) ago" } ?? "never")")
        print("captures_today: \(report.capturesToday)")
        print("errors_last_24h: \(facts.errorsLastDay)")
        print("index: \(facts.indexState.rawValue)")
        print("archive_bytes: \(report.archiveBytes)")
        print("disk_free_bytes: \(report.diskFreeBytes)")
        print("launch_agent: \(report.launchAgent.present ? report.launchAgent.plistPath : "not installed")")
        if report.launchAgent.present {
            print("launch_agent_program: \(report.launchAgent.programPath ?? "none") (\(report.launchAgent.programExists ? "present" : "MISSING"))")
            if let loaded = report.launchAgent.loadedInLaunchd {
                print("launch_agent_loaded: \(loaded)")
            }
        }
        for warning in report.verdict.warnings {
            print("warning: \(warning)")
        }
        if report.verdict.warnings.isEmpty {
            print("verdict: healthy")
        }
        return report.verdict.exit
    }
}
