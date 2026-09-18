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
        var indexVerifiedAt: Date?
        var lastRestoreVerifiedAt: Date?
    }

    static func gather(_ options: CLIOptions, askLaunchd: Bool) throws -> Report {
        let resolution = options.storeResolution
        var archiveIsDirectory: ObjCBool = false
        let storesPresent = FileManager.default.fileExists(atPath: options.archiveRoot.path, isDirectory: &archiveIsDirectory) && archiveIsDirectory.boolValue
        let lock = lockHolder(lockURL: resolution.lockURL)
        let loaded = ClipboardSettingsStore(settingsURL: resolution.settingsURL).loadReporting(readOnly: true)
        let settings = loaded.settings
        let now = ClipboardRuntime.now

        // Every retained row: a cap here would silently under-report the
        // error count on a busy log, which is the number most worth having.
        let operationalRows = options.operationalLog.read(limit: 0)
        let processRows = operationalRows.filter {
            guard let pid = lock.pid else { return false }
            return $0.numbers["pid"] == Double(pid)
        }
        let heartbeat = processRows.last { $0.code == "heartbeat" }
        let startup = processRows.last { $0.code == "app_start" }?.timestamp
        let dayAgo = now.addingTimeInterval(-86_400)
        let errorsLastDay = operationalRows.filter {
            $0.level == "error" && ($0.timestamp.map { $0 >= dayAgo } ?? false)
        }.count

        let recoveryCodes = ["capture_failed": "capture_recovered", "archive_append_failed": "capture_recovered",
            "index_rebuild_failed": "index_rebuild_finished", "index_upsert_failed": "index_rebuild_finished"]
        let activeErrors = operationalRows.enumerated().filter { position, row in
            guard row.level == "error", row.timestamp.map({ $0 >= dayAgo }) == true else { return false }
            guard let recovery = recoveryCodes[row.code] else { return true }
            return !operationalRows.dropFirst(position + 1).contains { $0.code == recovery }
        }.count

        let latestCapture = newestCapture(options)
        let usage = try readUsageRows(archiveRoot: options.archiveRoot)
        // Today's bucket by name, not the last bucket that has rows: on a
        // quiet day the latter would report an older day's count under a
        // heading that says today.
        let todayKey = ClipboardUsageStats.dayKey(for: now)
        let today = ClipboardUsageStats.summarize(usage: usage).days.first { $0.day == todayKey }

        let integrity = readIntegrity(options)
        let pausedPreference = ClipboardRuntime.isIsolated
            ? ClipboardPreferences().bool(forKey: "capturePaused")
            : (UserDefaults(suiteName: "app.clipboardarchive")?.bool(forKey: "capturePaused") ?? false)
        let facts = ClipboardStatusFacts(
            storesPresent: storesPresent,
            appRunning: lock.held,
            captureEnabled: settings.archiveEnabled,
            heartbeatAge: heartbeat?.timestamp.map { now.timeIntervalSince($0) },
            lastCaptureAge: latestCapture.map { now.timeIntervalSince($0) },
            errorsLastDay: errorsLastDay,
            indexState: integrity.index,
            launchAgentProgramMissing: false,
            launchAgentStoresDiffer: false,
            pollsSinceLastHeartbeat: heartbeat.map { safePollCount($0.numbers["polls"]) },
            startupAge: startup.map { now.timeIntervalSince($0) },
            captureSuspended: pausedPreference || settings.isTemporarilyPaused || settings.isPrivateModeActive,
            activeErrors: activeErrors
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

        var verdict = ClipboardStatusRules.verdict(resolvedFacts)
        if let fallback = loaded.fallback {
            verdict.warnings.append("Settings are not fully readable (\(fallback.rawValue)); review the saved configuration.")
        }
        if !options.operationalLog.sinkReadable {
            verdict.warnings.append("The operational log directory is unavailable.")
        }
        // Named here rather than silently folded into the index verdict: these
        // are real, they are not the index's, and before this they were the
        // problems `status` was reacting to without ever printing one of them.
        for problem in integrity.archiveProblems {
            verdict.warnings.append(problem)
        }
        for failure in options.operationalLog.unresolvedFailures {
            if failure == "failure_state_unreadable" {
                // A warning with no remedy is one an operator can only ignore.
                verdict.warnings.append(
                    "The unresolved-failure record could not be read; it is set aside "
                    + "as a .corrupt- copy the next time a failure is recorded.")
            } else {
                verdict.warnings.append("Unresolved operational failure: \(failure).")
            }
        }
        if !verdict.warnings.isEmpty && verdict.exit == .success { verdict.exit = .warnings }
        return Report(
            facts: resolvedFacts,
            verdict: verdict,
            lockPID: lock.held ? lock.pid : nil,
            capturesToday: today?.captures ?? 0,
            archiveBytes: archiveBytes(options),
            diskFreeBytes: diskFree(options.archiveRoot),
            latestCapture: latestCapture,
            latestHeartbeat: heartbeat?.timestamp,
            pollsSinceLastHeartbeat: safePollCount(heartbeat?.numbers["polls"]),
            launchAgent: agent,
            indexVerifiedAt: integrity.index == .fresh ? now : nil,
            lastRestoreVerifiedAt: ClipboardRestoreEvidence.read(archiveRoot: options.archiveRoot, settingsURL: resolution.settingsURL)?.verifiedAt
        )
    }

    private static func safePollCount(_ value: Double?) -> Int {
        guard let value, value.isFinite, value >= 0, value < Double(Int.max) else { return 0 }
        return Int(value)
    }

    /// Read the archive directly: asking the index here could self-heal it
    /// before status has a chance to report its damaged state.
    private static func newestCapture(_ options: CLIOptions) -> Date? {
        return try? ClipboardArchiveReader(archiveRoot: options.archiveRoot)
            .recentItems(since: .distantPast, limit: 1).first?.capturedAt
    }

    /// What ONE verification says, kept in the two halves it actually answers:
    /// how the index is doing, and what else is wrong that is not the index's
    /// fault. One `verify()` call feeds both — the archive is scanned once.
    struct IntegrityReading {
        var index: ClipboardStatusFacts.IndexState
        /// Real problems that `repair-index` cannot fix, so they are reported
        /// as their own warnings instead of being folded into the index line.
        var archiveProblems: [String]
    }

    /// Recompute integrity instead of treating modification time as proof.
    private static func readIntegrity(_ options: CLIOptions) -> IntegrityReading {
        guard FileManager.default.fileExists(atPath: options.indexPath.path) else {
            return IntegrityReading(index: .missing, archiveProblems: [])
        }
        // Recompute against this exact archive/index pair on every request.
        // No mtime-based or persisted success can survive a membership change.
        guard let result = try? ClipboardArchiveVerifier(archiveRoot: options.archiveRoot,
            indexURL: options.indexPath, settingsURL: options.storeResolution.settingsURL,
            pointerStatus: .absent).verify() else {
            return IntegrityReading(index: .invalid, archiveProblems: [])
        }
        return IntegrityReading(index: indexVerdict(result),
                                archiveProblems: result.archiveProblems)
    }

    /// Grade the INDEX on index evidence only.
    ///
    /// The membership split is the point. `verify()` is two independent full
    /// scans — eligible events, then indexed rows — with no snapshot between
    /// them, so on a machine that is merely capturing, an event landing between
    /// the two reads shows up as `missingFromIndex`. That is indistinguishable
    /// from an index that is genuinely behind, and BOTH are honestly described
    /// as "catch it up", which is what `.stale` already says. An `extraInIndex`
    /// row is different in kind: no capture can add one, so the index really is
    /// claiming a clip the archive does not have, and that earns `.invalid`.
    private static func indexVerdict(_ result: ClipboardVerification) -> ClipboardStatusFacts.IndexState {
        if !result.indexExists { return .missing }
        if !result.indexReadable || !result.indexIntegrityOK { return .invalid }
        if result.extraInIndex > 0 { return .invalid }
        if result.missingFromIndex > 0 { return .stale }
        return .fresh
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
                "index_verified_at": report.indexVerifiedAt.map { ISO8601DateFormatter().string(from: $0) } as Any? ?? NSNull(),
                "last_successful_restore_verified_at": report.lastRestoreVerifiedAt.map { ISO8601DateFormatter().string(from: $0) } as Any? ?? NSNull(),
                "archive_bytes": report.archiveBytes,
                "disk_free_bytes": report.diskFreeBytes,
                // Which stores this answer is ABOUT. Without it a reader
                // cannot tell a scratch measurement from a production one,
                // and a run that fell back to the real stores looks identical
                // to one that was pinned at them on purpose.
                "stores": [
                    "archive_root": options.storeResolution.archiveRoot.path,
                    "archive_origin": options.storeResolution.archiveOrigin.rawValue,
                    "index_path": options.storeResolution.indexPath.path,
                    "index_origin": options.storeResolution.indexOrigin.rawValue,
                    "application_support_root": options.storeResolution.applicationSupportRoot.path,
                    "isolation_breach": ClipboardRuntime.isolationBreach().map { $0.sentence as Any } ?? NSNull()
                ],
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
        print("index_verified_at: \(report.indexVerifiedAt.map { ISO8601DateFormatter().string(from: $0) } ?? "never")")
        print("last_successful_restore_verified_at: \(report.lastRestoreVerifiedAt.map { ISO8601DateFormatter().string(from: $0) } ?? "never")")
        print("archive_bytes: \(report.archiveBytes)")
        print("disk_free_bytes: \(report.diskFreeBytes)")
        print("archive_root: \(options.storeResolution.archiveRoot.path) (\(options.storeResolution.archiveOrigin.rawValue))")
        print("index_path: \(options.storeResolution.indexPath.path) (\(options.storeResolution.indexOrigin.rawValue))")
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
