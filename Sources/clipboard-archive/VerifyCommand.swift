import ClipboardArchiveCore
import Foundation

enum VerifyCommand {
    static func run(_ options: CLIOptions) throws -> ClipboardCLIExit {
        try CLIOutcome.requireArchive(options)
        let result = try ClipboardArchiveVerifier(
            archiveRoot: options.archiveRoot,
            indexURL: options.indexPath,
            settingsURL: options.storeResolution.settingsURL,
            pointerStatus: options.storeResolution.pointerStatus
        ).verify()

        if options.json {
            CLIOutcome.printJSON([
                "schema": 1,
                "eligible_events": result.eligibleEvents,
                "indexed_events": result.indexedEvents,
                "missing_from_index": result.missingFromIndex,
                "extra_in_index": result.extraInIndex,
                "index_exists": result.indexExists,
                "index_readable": result.indexReadable,
                "index_integrity_ok": result.indexIntegrityOK,
                "settings_readable": result.settingsReadable,
                "pointer_status": result.pointerStatus.rawValue,
                "invalid_json_lines": result.health.invalidJSONLines,
                "missing_body_files": result.health.missingBodyFiles,
                "unsafe_body_paths": result.health.unsafeBodyPaths,
                "insecure_files": result.health.insecureFiles,
                "orphaned_rich_bodies": result.health.orphanedRichBodyFiles,
                "stored_events": result.health.storedEvents,
                "problems": result.problems,
                "exit": result.exit.rawValue
            ])
            return result.exit
        }

        print("Clipboard Archive verify")
        print("archive: \(result.health.archiveRoot)")
        print("stored_events: \(result.health.storedEvents)")
        print("eligible_events: \(result.eligibleEvents)")
        print("indexed_events: \(result.indexedEvents)")
        print("missing_from_index: \(result.missingFromIndex)")
        print("extra_in_index: \(result.extraInIndex)")
        print("index_integrity_ok: \(result.indexIntegrityOK)")
        print("invalid_json: \(result.health.invalidJSONLines)")
        print("missing_bodies: \(result.health.missingBodyFiles)")
        print("unsafe_body_paths: \(result.health.unsafeBodyPaths)")
        print("insecure_files: \(result.health.insecureFiles)")
        print("orphaned_rich_bodies: \(result.health.orphanedRichBodyFiles)")
        print("pointer_status: \(result.pointerStatus.rawValue)")
        if result.problems.isEmpty {
            print("verdict: no problems found")
        } else {
            for problem in result.problems {
                print("problem: \(problem)")
            }
        }
        return result.exit
    }
}

enum DoctorCommand {
    /// Worst first. The exit numbers are names, not a ladder — 5 is
    /// "finished, with something to say" and 4 is "found real problems" —
    /// so picking the larger number would report the milder outcome.
    private static let severity: [ClipboardCLIExit] = [.success, .warnings, .integrity, .store, .runtime]

    private static func worse(_ left: ClipboardCLIExit, _ right: ClipboardCLIExit) -> ClipboardCLIExit {
        let leftRank = severity.firstIndex(of: left) ?? 0
        let rightRank = severity.firstIndex(of: right) ?? 0
        return leftRank >= rightRank ? left : right
    }

    /// Stores, status and verify in one page, with the worst of their exit
    /// codes. The point is one command to run when something feels wrong,
    /// whose output can be read without knowing which part said what.
    static func run(_ options: CLIOptions) throws -> ClipboardCLIExit {
        let resolution = options.storeResolution
        let statusReport = try StatusCommand.gather(options, askLaunchd: true)
        let verification = FileManager.default.fileExists(atPath: options.archiveRoot.path)
            ? try? ClipboardArchiveVerifier(
                archiveRoot: options.archiveRoot,
                indexURL: options.indexPath,
                settingsURL: options.storeResolution.settingsURL,
                pointerStatus: options.storeResolution.pointerStatus
            ).verify()
            : nil

        let statusExit = statusReport.verdict.exit
        let verifyExit = verification?.exit ?? .store
        let worst = worse(statusExit, verifyExit)

        if options.json {
            CLIOutcome.printJSON([
                "schema": 1,
                "archive": resolution.archiveRoot.path,
                "archive_origin": resolution.archiveOrigin.rawValue,
                "index": resolution.indexPath.path,
                "index_origin": resolution.indexOrigin.rawValue,
                "status_exit": statusExit.rawValue,
                "verify_exit": verifyExit.rawValue,
                "warnings": statusReport.verdict.warnings,
                "problems": verification?.problems ?? ["The archive is not where this command looked for it."],
                "exit": worst.rawValue
            ])
            return worst
        }

        print("Clipboard Archive doctor")
        print("")
        print("Stores")
        print("  archive: \(resolution.archiveRoot.path) (\(resolution.archiveOrigin.rawValue))")
        print("  index: \(resolution.indexPath.path) (\(resolution.indexOrigin.rawValue))")
        print("  pointer: \(resolution.pointerStatus.rawValue)")
        print("")
        print("Running")
        print("  the app is \(statusReport.facts.appRunning ? "running" : "not running")\(statusReport.lockPID.map { " (pid \($0))" } ?? "")")
        print("  capture is \(statusReport.facts.captureEnabled ? "on" : "off")")
        print("  last capture: \(statusReport.facts.lastCaptureAge.map { "\(ClipboardStatusRules.describe($0)) ago" } ?? "never")")
        print("  last heartbeat: \(statusReport.facts.heartbeatAge.map { "\(ClipboardStatusRules.describe($0)) ago" } ?? "never")")
        print("")
        print("Archive and index")
        if let verification {
            print("  \(verification.health.storedEvents) clips stored, \(verification.indexedEvents) in the search index")
            print("  \(verification.missingFromIndex) missing from the index, \(verification.extraInIndex) extra in it")
        } else {
            print("  there is no archive at that path, so nothing could be checked")
        }
        print("")
        let problems = statusReport.verdict.warnings + (verification?.problems ?? [])
        if problems.isEmpty {
            print("Verdict: everything checks out.")
        } else {
            print("Verdict: \(problems.count) thing\(problems.count == 1 ? "" : "s") to look at.")
            for problem in problems {
                print("  - \(problem)")
            }
        }
        return worst
    }
}

enum VersionCommand {
    static func run(_ options: CLIOptions) -> ClipboardCLIExit {
        let identity = ClipboardRotatingLogFile.bundleVersion()
        let appVersion = ClipboardVersionInfo.currentAppVersion()
        let info = ClipboardVersionInfo(
            appVersion: appVersion,
            appBuild: identity.build > 0 ? String(identity.build) : nil
        )
        if options.json {
            CLIOutcome.printJSON([
                "schema": 1,
                "app_version": appVersion,
                "build": identity.build,
                "event_schema_version": info.eventSchemaVersion,
                "index_schema_version": info.indexSchemaVersion,
                "archive_format_version": ClipboardVersionInfo.archiveFormatVersion
            ])
            return .success
        }
        for line in info.summaryLines {
            print(line)
        }
        return .success
    }
}
