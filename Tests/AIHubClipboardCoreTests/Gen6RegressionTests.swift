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
