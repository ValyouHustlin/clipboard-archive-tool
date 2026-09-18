import Foundation
import Testing
@testable import ClipboardArchiveCore

/// Regressions for the cycle-2 certification findings this lane accepted as
/// real. Each test names the wrong behaviour it locks out.
///
/// The half-isolated run is the one that caused the most damage in cycle 2 and
/// left no trace while doing it: the certifier pinned the archive and index
/// into scratch, lost the support-root variable to shell word-splitting, and
/// graded PRODUCTION twice while every surface it read looked isolated. The
/// detector has to key on the PATH being scratch rather than on a variable
/// being set, because the real launch agent legitimately pins the archive and
/// index to their production paths and must stay silent.
@Suite("Gen6 certification regressions")
struct Gen6RegressionTests {
    private let support = ClipboardDefaults.applicationSupportEnvironmentKey
    private let archive = ClipboardDefaults.archiveEnvironmentKey
    private let index = ClipboardDefaults.indexEnvironmentKey

    // MARK: - CA-C2-08: a half-isolated run must say so

    /// The cycle-2 failure exactly: stores pinned into scratch, support root
    /// missing, so preferences, the pasteboard, the clock seam and the log
    /// directory all stayed on the user's real data.
    @Test func scratchStoresWithoutTheSupportRootAreReportedAsABreach() {
        let breach = ClipboardRuntime.isolationBreach(environment: [
            archive: "/tmp/scratch-run/archive",
            index: "/tmp/scratch-run/index/search.sqlite"
        ])
        #expect(breach != nil)
        #expect(breach?.scratchKeys == [archive, index])
        // The remedy names the variable to set; a warning without it sends an
        // operator looking for the wrong problem.
        #expect(breach?.sentence.contains(support) == true)
    }

    /// A properly isolated run is silent. Anything else trains people to
    /// ignore the warning that matters.
    @Test func aFullyIsolatedRunIsNotABreach() {
        let breach = ClipboardRuntime.isolationBreach(environment: [
            support: "/tmp/scratch-run/support",
            archive: "/tmp/scratch-run/archive",
            index: "/tmp/scratch-run/index/search.sqlite"
        ])
        #expect(breach == nil)
    }

    /// The real launch agent pins the archive and the index to their
    /// PRODUCTION paths and sets no support root. That is ordinary
    /// configuration, not a breach, and a detector keyed on the variable being
    /// present rather than on the path being scratch would warn on every
    /// launch of the shipped app.
    @Test func theLaunchAgentPinningProductionPathsIsNotABreach() {
        let breach = ClipboardRuntime.isolationBreach(environment: [
            archive: "/Users/someone/Development/AI-Hub-Archive/clipboard-history",
            index: "/Users/someone/Development/AI/data/clipboard-history/indexes/clipboard-search.sqlite"
        ])
        #expect(breach == nil)
    }

    @Test func anOrdinaryRunWithNoStoreVariablesIsNotABreach() {
        #expect(ClipboardRuntime.isolationBreach(environment: [:]) == nil)
    }

    /// An empty value is not a set variable. Shell word-splitting produces
    /// exactly this, and treating it as "pinned" would report a breach for a
    /// run that never asked for one.
    @Test func anEmptyStoreVariableIsNotAPin() {
        #expect(ClipboardRuntime.isolationBreach(environment: [archive: ""]) == nil)
    }

    /// `/private/tmp` is the resolved form of `/tmp` on this platform, and the
    /// scratchpad a harness is handed is spelled that way.
    @Test func thePrivateTmpSpellingCountsAsScratch() {
        let breach = ClipboardRuntime.isolationBreach(environment: [
            archive: "/private/tmp/claude-501/session/archive"
        ])
        #expect(breach?.scratchKeys == [archive])
    }
}

/// CA-C2-01. A pause reaches into the verdict and disarms every check that
/// would say capture has stopped. Before this, the whole branch was skipped
/// when suspended, so a machine paused ten years out answered exit 0 with an
/// empty warning list while nothing had been archived since the pause began —
/// a green status over a dead capture loop, which is the bar's named failure.
@Suite("Gen6 pause reporting")
struct Gen6PauseTests {
    private func facts(
        suspended: Bool,
        suspendedFor: TimeInterval? = nil,
        appRunning: Bool = true
    ) -> ClipboardStatusFacts {
        ClipboardStatusFacts(
            storesPresent: true,
            appRunning: appRunning,
            captureEnabled: true,
            heartbeatAge: 60,
            lastCaptureAge: 120,
            errorsLastDay: 0,
            indexState: .fresh,
            captureSuspended: suspended,
            captureSuspendedForSeconds: suspendedFor
        )
    }

    @Test func aPausedCaptureIsNeverGreen() {
        let verdict = ClipboardStatusRules.verdict(facts(suspended: true))
        #expect(verdict.exit == .warnings)
        #expect(verdict.isHealthy == false)
        #expect(verdict.warnings.contains { $0.contains("paused") })
    }

    /// The duration is the whole point: "paused" alone cannot tell a ten
    /// minute break from a silence that outlasts the year.
    @Test func thePauseWarningNamesHowMuchLongerItRuns() {
        let verdict = ClipboardStatusRules.verdict(facts(suspended: true, suspendedFor: 7 * 24 * 60 * 60))
        #expect(verdict.warnings.contains { $0.contains("7 days") })
    }

    /// A paused machine whose app has also died still reports the pause
    /// rather than falling silent on both.
    @Test func aPausedCaptureWithNoAppRunningStillWarns() {
        let verdict = ClipboardStatusRules.verdict(facts(suspended: true, appRunning: false))
        #expect(verdict.exit == .warnings)
    }

    @Test func anUnpausedHealthyMachineIsStillGreen() {
        let verdict = ClipboardStatusRules.verdict(facts(suspended: false))
        #expect(verdict.exit == .success)
        #expect(verdict.warnings.isEmpty)
    }
}

/// The clamp that stops an absurd pause existing in the first place.
@Suite("Gen6 pause clamp")
struct Gen6PauseClampTests {
    @Test func aTenYearPauseIsBoundedToTheMaximum() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let absurd = now.addingTimeInterval(10 * 365 * 24 * 60 * 60)
        let clamped = ClipboardSettings.clampPause(absurd, now: now)
        #expect(clamped == now.addingTimeInterval(ClipboardSettings.maximumPauseInterval))
    }

    /// The menu bar's longest pause is "until tomorrow". Nothing the app
    /// itself writes may be moved by the clamp.
    @Test func anOrdinaryPauseIsLeftExactlyAsItWas() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let tomorrow = now.addingTimeInterval(24 * 60 * 60)
        #expect(ClipboardSettings.clampPause(tomorrow, now: now) == tomorrow)
    }

    /// A date already past is not a pause. Moving it forward would invent one.
    @Test func anExpiredPauseIsNotMovedForward() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let past = now.addingTimeInterval(-60)
        #expect(ClipboardSettings.clampPause(past, now: now) == past)
    }

    @Test func noPauseStaysNoPause() {
        #expect(ClipboardSettings.clampPause(nil, now: Date()) == nil)
    }

    /// Through the FILE, not just the pure function. The clamp has to happen
    /// where an absurd value actually arrives — a settings document someone
    /// hand-edited or a corrupted write — or it protects nothing.
    @Test func aFarFuturePauseInTheSettingsFileIsBoundedOnLoad() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("clipboard-gen6-clamp-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("settings.json")

        let tenYears = ClipboardRuntime.now.addingTimeInterval(10 * 365 * 24 * 60 * 60)
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        let document = """
        {"archiveEnabled":true,"hasCompletedOnboarding":true,"settingsVersion":1,\
        "pauseUntil":"\(formatter.string(from: tenYears))"}
        """
        try Data(document.utf8).write(to: url)

        let loaded = ClipboardSettingsStore(settingsURL: url).load()
        let remaining = try #require(loaded.remainingPauseInterval)
        #expect(remaining <= ClipboardSettings.maximumPauseInterval + 5)
        // Still a pause — the clamp bounds it, it does not cancel it.
        #expect(loaded.isTemporarilyPaused)
    }
}
