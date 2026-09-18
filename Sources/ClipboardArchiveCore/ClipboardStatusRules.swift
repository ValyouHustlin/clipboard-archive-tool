import Foundation

/// What `status` found, separated from how it found it.
///
/// Gathering these facts means reading a lock file, a log, an index and a
/// launch agent; deciding what they mean is arithmetic. Keeping the second
/// part pure is what lets the verdict be tested without a machine in a
/// particular state.
public struct ClipboardStatusFacts: Sendable, Equatable {
    public enum IndexState: String, Sendable, Codable {
        case fresh, stale, missing, invalid
    }

    /// False when the archive root is not there at all.
    public var storesPresent: Bool
    /// True when a live process holds the single-instance lock.
    public var appRunning: Bool
    public var captureEnabled: Bool
    /// Age of the newest heartbeat row, nil when there has never been one.
    public var heartbeatAge: TimeInterval?
    /// How old a heartbeat may be before it counts as gone quiet.
    public var heartbeatTolerance: TimeInterval
    public var pollsSinceLastHeartbeat: Int?
    public var startupAge: TimeInterval?
    public var captureSuspended: Bool
    /// How much longer a suspension has to run, when the surface knows.
    public var captureSuspendedForSeconds: TimeInterval?
    public var lastCaptureAge: TimeInterval?
    public var errorsLastDay: Int
    public var activeErrors: Int?
    public var indexState: IndexState
    /// True when the launch agent names a program that is not on disk.
    public var launchAgentProgramMissing: Bool
    /// True when the launch agent pins stores other than the resolved ones.
    public var launchAgentStoresDiffer: Bool

    public init(
        storesPresent: Bool,
        appRunning: Bool,
        captureEnabled: Bool,
        heartbeatAge: TimeInterval?,
        heartbeatTolerance: TimeInterval = 3_600,
        lastCaptureAge: TimeInterval?,
        errorsLastDay: Int,
        indexState: IndexState,
        launchAgentProgramMissing: Bool = false,
        launchAgentStoresDiffer: Bool = false,
        pollsSinceLastHeartbeat: Int? = nil,
        startupAge: TimeInterval? = nil,
        captureSuspended: Bool = false,
        captureSuspendedForSeconds: TimeInterval? = nil,
        activeErrors: Int? = nil
    ) {
        self.pollsSinceLastHeartbeat = pollsSinceLastHeartbeat
        self.startupAge = startupAge
        self.captureSuspended = captureSuspended
        self.captureSuspendedForSeconds = captureSuspendedForSeconds
        self.storesPresent = storesPresent
        self.appRunning = appRunning
        self.captureEnabled = captureEnabled
        self.heartbeatAge = heartbeatAge
        self.heartbeatTolerance = heartbeatTolerance
        self.lastCaptureAge = lastCaptureAge
        self.errorsLastDay = errorsLastDay
        self.activeErrors = activeErrors
        self.indexState = indexState
        self.launchAgentProgramMissing = launchAgentProgramMissing
        self.launchAgentStoresDiffer = launchAgentStoresDiffer
    }
}

public struct ClipboardStatusVerdict: Sendable, Equatable {
    public var exit: ClipboardCLIExit
    /// One plain sentence per thing worth saying, in the order found.
    public var warnings: [String]

    public var isHealthy: Bool {
        exit == .success
    }
}

public enum ClipboardStatusRules {
    /// The whole judgement, in one place.
    ///
    /// Missing stores beat everything: there is nothing to grade. Otherwise
    /// every warning is collected — a report that stops at the first problem
    /// hides the second one — and the presence of any warning is exit 5.
    public static func verdict(_ facts: ClipboardStatusFacts) -> ClipboardStatusVerdict {
        guard facts.storesPresent else {
            return ClipboardStatusVerdict(
                exit: .store,
                warnings: ["The archive is not where this command looked for it."]
            )
        }

        var warnings: [String] = []

        // A heartbeat is the only thing that says capture is still running
        // rather than merely launched, so its absence is the finding.
        if let age = facts.heartbeatAge, age < -5 {
            warnings.append("The heartbeat timestamp is in the future; capture progress cannot be trusted.")
        }
        if facts.captureEnabled && !facts.captureSuspended {
            if facts.appRunning {
                let starting = facts.startupAge.map { $0 >= 0 && $0 < 60 } ?? false
                if facts.pollsSinceLastHeartbeat == 0 && !starting {
                    warnings.append("The app is running but the last heartbeat reports no clipboard polls.")
                }
                if let age = facts.heartbeatAge {
                    if age > facts.heartbeatTolerance {
                        warnings.append(
                            "Capture is on and the app is running, but it last reported \(describe(age)) ago."
                        )
                    }
                } else if !starting {
                    warnings.append("Capture is on and the app is running, but it has never reported in.")
                }
            } else {
                warnings.append("Capture is on but the app is not running, so nothing is being archived.")
            }
        } else if facts.captureEnabled && facts.captureSuspended {
            // A pause disarms every check above it. Reporting the pause is
            // what keeps that from reading as health: before this, a machine
            // paused ten years out answered exit 0 with no warnings at all,
            // while nothing had been archived since the pause began.
            let duration = facts.captureSuspendedForSeconds.map { " for another \(describe($0))" } ?? ""
            warnings.append(
                "Capture is on but paused\(duration), so nothing is being archived and "
                + "the checks that would say so are disarmed."
            )
        }

        switch facts.indexState {
        case .fresh:
            break
        case .stale:
            warnings.append("The search index is older than the archive; run repair-index to catch it up.")
        case .invalid:
            warnings.append("The search index does not match the archive or failed verification; run verify, then repair-index.")
        case .missing:
            warnings.append("There is no search index; All History and index searches will rebuild it first.")
        }

        let errorCount = facts.activeErrors ?? facts.errorsLastDay
        if errorCount > 0 {
            warnings.append(
                "\(errorCount) unresolved error\(errorCount == 1 ? "" : "s") recorded in the last 24 hours."
            )
        }

        if facts.launchAgentProgramMissing {
            warnings.append("The launch agent points at a program that is not there, so it cannot start the app.")
        }

        if facts.launchAgentStoresDiffer {
            warnings.append("The launch agent pins different stores than this command resolved.")
        }

        return ClipboardStatusVerdict(exit: warnings.isEmpty ? .success : .warnings, warnings: warnings)
    }

    /// "4 minutes", "2 hours", "3 days" — the shape a person reads.
    public static func describe(_ interval: TimeInterval) -> String {
        let seconds = Int(interval.rounded())
        if seconds < 120 {
            return "\(max(0, seconds)) second\(seconds == 1 ? "" : "s")"
        }
        let minutes = seconds / 60
        if minutes < 120 {
            return "\(minutes) minute\(minutes == 1 ? "" : "s")"
        }
        let hours = minutes / 60
        if hours < 48 {
            return "\(hours) hour\(hours == 1 ? "" : "s")"
        }
        let days = hours / 24
        return "\(days) day\(days == 1 ? "" : "s")"
    }
}
