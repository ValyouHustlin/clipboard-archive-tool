import Foundation
import Testing
@testable import ClipboardArchiveCore

/// The command line's promises: what each exit code means, what an export
/// file may hold, what the usage summary adds up to, what `status` decides,
/// and that the committed reference still matches the table it is generated
/// from. Synthetic data only, temporary roots only.
@Suite("CLI contract")
struct CLIContractTests {
    // MARK: - Exit codes

    @Test func exitCodesAreTheDocumentedNumbers() {
        #expect(ClipboardCLIExit.success.rawValue == 0)
        #expect(ClipboardCLIExit.runtime.rawValue == 1)
        #expect(ClipboardCLIExit.usage.rawValue == 2)
        #expect(ClipboardCLIExit.store.rawValue == 3)
        #expect(ClipboardCLIExit.integrity.rawValue == 4)
        #expect(ClipboardCLIExit.warnings.rawValue == 5)
    }

    /// Only the failures carry a machine-readable code; success and a
    /// completed-with-warnings run are not errors and must not print one.
    @Test func onlyFailuresCarryAnErrorCode() {
        #expect(ClipboardCLIExit.success.errorCode == nil)
        #expect(ClipboardCLIExit.warnings.errorCode == nil)
        #expect(ClipboardCLIExit.usage.errorCode == "usage")
        #expect(ClipboardCLIExit.runtime.errorCode == "runtime")
        #expect(ClipboardCLIExit.store.errorCode == "store")
        #expect(ClipboardCLIExit.integrity.errorCode == "integrity")
    }

    // MARK: - Verb table and the generated reference

    @Test func everyVerbHasASummaryAndAUsageLine() {
        #expect(!ClipboardCLIVerbs.all.isEmpty)
        for verb in ClipboardCLIVerbs.all {
            #expect(!verb.summary.isEmpty, "\(verb.name) has no summary")
            #expect(verb.usage.contains(verb.name), "\(verb.name)'s usage line does not name it")
        }
        let names = ClipboardCLIVerbs.all.map(\.name)
        #expect(Set(names).count == names.count, "a verb is listed twice")
    }

    @Test func overviewNamesEveryVerb() {
        let overview = ClipboardCLIVerbs.overview()
        for verb in ClipboardCLIVerbs.all {
            #expect(overview.contains(verb.name), "help does not list \(verb.name)")
        }
    }

    /// The drift guard: `docs/CLI.md` is generated from the table above, so
    /// a verb added without regenerating it fails here rather than shipping
    /// a reference that describes a tool that no longer exists.
    @Test func committedReferenceMatchesTheTable() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let referenceURL = repositoryRoot.appendingPathComponent("docs/CLI.md")
        let committed = try String(contentsOf: referenceURL, encoding: .utf8)
        let generated = ClipboardCLIVerbs.markdownReference()
        if committed != generated {
            let committedLines = committed.split(separator: "\n", omittingEmptySubsequences: false)
            let generatedLines = generated.split(separator: "\n", omittingEmptySubsequences: false)
            let firstDifference = zip(committedLines, generatedLines).enumerated()
                .first { $0.element.0 != $0.element.1 }
            print("CLI_DOC_DRIFT first_differing_line=\(firstDifference?.offset.description ?? "length")")
        }
        #expect(committed == generated, "docs/CLI.md is out of date: regenerate with `clipboard-archive help --markdown`")
    }

    // MARK: - Export rules

    private func event(
        id: String,
        label: PrivacyLabel,
        hash: String = "sha256:fixture"
    ) -> StoredClipboardEvent {
        var clip = SyntheticFixtures.currentEvent(id: id)
        clip.privacyLabel = label
        clip.contentHash = hash
        return clip
    }

    @Test func exportKeepsAnOrdinaryClip() {
        let clip = event(id: "clip_a", label: .privateLocal)
        let suppression = ClipboardSuppression.Snapshot(deletedIDs: [])
        #expect(ClipboardExportRules.isExportable(clip, suppression: suppression, sensitivityOverride: nil))
    }

    @Test func exportLeavesOutEveryKindOfRestrictedClip() {
        let suppression = ClipboardSuppression.Snapshot(deletedIDs: ["clip_deleted"])
        #expect(
            ClipboardExportRules.exclusion(
                for: event(id: "clip_deleted", label: .privateLocal),
                suppression: suppression,
                sensitivityOverride: nil
            ) == .suppressed
        )
        #expect(
            ClipboardExportRules.exclusion(
                for: event(id: "clip_tombstoned", label: .doNotIndex),
                suppression: suppression,
                sensitivityOverride: nil
            ) == .suppressed
        )
        #expect(
            ClipboardExportRules.exclusion(
                for: event(id: "clip_restricted", label: .restricted),
                suppression: suppression,
                sensitivityOverride: nil
            ) == .restricted
        )
        #expect(
            ClipboardExportRules.exclusion(
                for: event(id: "clip_marked", label: .privateLocal),
                suppression: suppression,
                sensitivityOverride: "restricted"
            ) == .manuallyRestricted
        )
    }

    /// An override that is not the restricted marker must not exclude
    /// anything: the rule is a specific word, not "any annotation".
    @Test func anUnrelatedSensitivityOverrideDoesNotExclude() {
        let suppression = ClipboardSuppression.Snapshot(deletedIDs: [])
        #expect(
            ClipboardExportRules.isExportable(
                event(id: "clip_b", label: .privateLocal),
                suppression: suppression,
                sensitivityOverride: "reviewed"
            )
        )
    }

    @Test func exportFilesAreOwnerOnly() {
        #expect(ClipboardExportRules.filePermissions == 0o600)
    }

    // MARK: - Stats

    private func usageRow(_ event: String, _ outcome: String, _ scope: String, _ day: Int, _ ms: Double = 0) -> ClipboardUsageRow {
        ClipboardUsageRow(
            timestamp: Date(timeIntervalSince1970: 1_800_000_000 + Double(day) * 86_400),
            event: event,
            outcome: outcome,
            scope: scope,
            count: 1,
            durationMs: ms
        )
    }

    @Test func statsCountPerDayAndInTotal() {
        let summary = ClipboardUsageStats.summarize(usage: [
            usageRow("capture", "success", "application", 0),
            usageRow("capture", "success", "application", 0),
            usageRow("blocked", "excluded", "application", 0),
            usageRow("search", "hit", "this_window", 0, 12),
            usageRow("search", "miss", "all_history", 1, 900),
            usageRow("error", "failed", "archive", 1),
            usageRow("capture", "success", "application", 1)
        ])
        #expect(summary.days.count == 2)
        #expect(summary.days[0].captures == 2)
        #expect(summary.days[0].blocked == 1)
        #expect(summary.days[0].searchHits == 1)
        #expect(summary.days[1].searchMisses == 1)
        #expect(summary.days[1].errors == 1)
        #expect(summary.totalCaptures == 3)
        #expect(summary.totalSearches == 2)
        #expect(summary.totalErrors == 1)
    }

    /// Nearest rank: every number reported is a measurement that happened.
    @Test func latencyPercentilesComeFromRealSamples() {
        let latency = ClipboardUsageStats.latency(of: [10, 20, 30, 40, 50, 60, 70, 80, 90, 100])
        #expect(latency.samples == 10)
        #expect(latency.p50Ms == 50)
        #expect(latency.p90Ms == 90)
        #expect(latency.maxMs == 100)
        let single = ClipboardUsageStats.latency(of: [7])
        #expect(single.p50Ms == 7 && single.p90Ms == 7 && single.maxMs == 7)
        let none = ClipboardUsageStats.latency(of: [])
        #expect(none.samples == 0 && none.maxMs == 0)
    }

    @Test func statsHonourTheSinceCutoff() {
        let rows = [usageRow("capture", "success", "application", 0), usageRow("capture", "success", "application", 5)]
        let summary = ClipboardUsageStats.summarize(
            usage: rows,
            since: Date(timeIntervalSince1970: 1_800_000_000 + 86_400)
        )
        #expect(summary.totalCaptures == 1)
        #expect(summary.days.count == 1)
    }

    // MARK: - Status verdicts

    private func facts(
        storesPresent: Bool = true,
        appRunning: Bool = true,
        captureEnabled: Bool = true,
        heartbeatAge: TimeInterval? = 60,
        lastCaptureAge: TimeInterval? = 120,
        errorsLastDay: Int = 0,
        indexState: ClipboardStatusFacts.IndexState = .fresh,
        programMissing: Bool = false,
        storesDiffer: Bool = false
    ) -> ClipboardStatusFacts {
        ClipboardStatusFacts(
            storesPresent: storesPresent,
            appRunning: appRunning,
            captureEnabled: captureEnabled,
            heartbeatAge: heartbeatAge,
            lastCaptureAge: lastCaptureAge,
            errorsLastDay: errorsLastDay,
            indexState: indexState,
            launchAgentProgramMissing: programMissing,
            launchAgentStoresDiffer: storesDiffer
        )
    }

    @Test func aHealthyMachineExitsZero() {
        let verdict = ClipboardStatusRules.verdict(facts())
        #expect(verdict.exit == .success)
        #expect(verdict.warnings.isEmpty)
    }

    @Test func missingStoresBeatEverythingElse() {
        let verdict = ClipboardStatusRules.verdict(facts(storesPresent: false, indexState: .missing))
        #expect(verdict.exit == .store)
        #expect(verdict.warnings.count == 1)
    }

    /// The dead-man case this exists for: capture is on, the process is
    /// alive, and it has not said anything for hours.
    @Test func aQuietHeartbeatIsAWarning() {
        let verdict = ClipboardStatusRules.verdict(facts(heartbeatAge: 7_200))
        #expect(verdict.exit == .warnings)
        #expect(verdict.warnings.contains { $0.contains("last reported") })
    }

    @Test func captureOnWithNoAppRunningIsAWarning() {
        let verdict = ClipboardStatusRules.verdict(facts(appRunning: false, heartbeatAge: nil))
        #expect(verdict.exit == .warnings)
        #expect(verdict.warnings.contains { $0.contains("not running") })
    }

    /// Capture turned off is a choice, not a fault: a heartbeat that is
    /// silent because nothing is meant to be running must not warn.
    @Test func captureDeliberatelyOffIsNotAWarning() {
        let verdict = ClipboardStatusRules.verdict(
            facts(captureEnabled: false, heartbeatAge: 100_000, lastCaptureAge: 100_000)
        )
        #expect(verdict.exit == .success)
    }

    @Test func everyProblemIsReportedNotJustTheFirst() {
        let verdict = ClipboardStatusRules.verdict(
            facts(heartbeatAge: 7_200, errorsLastDay: 3, indexState: .stale, programMissing: true, storesDiffer: true)
        )
        #expect(verdict.exit == .warnings)
        #expect(verdict.warnings.count == 5)
    }
}
