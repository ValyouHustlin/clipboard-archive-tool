import Foundation
import Testing
@testable import ClipboardArchiveCore

/// Slice 9: About-section version assembly. Pins that the surfaced numbers
/// come from the owning constants (never re-hardcoded), that the release
/// URL is ONE constant with the exact allowlisted value, and that the
/// update guidance stays honest about being manual.
@Suite("Version Info")
struct VersionInfoTests {
    @Test
    func testDefaultsTrackTheOwningConstants() {
        let info = ClipboardVersionInfo(appVersion: "0.2.0", appBuild: "5")
        #expect(info.eventSchemaVersion == StoredClipboardEvent.currentSchemaVersion)
        #expect(info.indexSchemaVersion == ClipboardDerivedIndex.currentIndexSchemaVersion)
        #expect(ClipboardVersionInfo.archiveFormatVersion == 1)
    }

    @Test
    func testVersionDisplayWithAndWithoutBuild() {
        #expect(
            ClipboardVersionInfo(appVersion: "0.2.0", appBuild: "5").versionDisplay
                == "Version 0.2.0 (5)"
        )
        #expect(
            ClipboardVersionInfo(appVersion: "0.2.0").versionDisplay == "Version 0.2.0"
        )
        #expect(
            ClipboardVersionInfo(appVersion: "0.2.0", appBuild: "").versionDisplay
                == "Version 0.2.0"
        )
    }

    @Test
    func testSummaryLinesCarryEveryVersionFactAndTheManualUpdateStory() {
        let info = ClipboardVersionInfo(appVersion: "0.2.0", appBuild: "5")
        let lines = info.summaryLines
        #expect(lines.count == 3)
        #expect(lines[0] == "Version 0.2.0 (5)")
        #expect(lines[1].contains("Archive format v\(ClipboardVersionInfo.archiveFormatVersion)"))
        #expect(lines[1].contains("event schema v\(StoredClipboardEvent.currentSchemaVersion)"))
        #expect(
            lines[1].contains(
                "search index schema v\(ClipboardDerivedIndex.currentIndexSchemaVersion)"
            )
        )
        #expect(lines[2] == ClipboardVersionInfo.updateGuidance)
        #expect(lines[2].contains("manual"))
    }

    @Test
    func testReleasePageURLIsTheSingleAllowlistedConstant() {
        // check-local-only.sh allowlists exactly this literal (source scan
        // and binary strings scan). If the value changes, BOTH allowlist
        // entries must change in the same commit — this test is the guard.
        #expect(
            ClipboardVersionInfo.releasePageURLString
                == "https://github.com/ValyouHustlin/clipboard-archive-tool/releases"
        )
        // It must parse as a URL for the user-initiated open action, but
        // nothing in Core or the app ever fetches it.
        #expect(URL(string: ClipboardVersionInfo.releasePageURLString) != nil)
    }

    @Test
    func testCurrentSchemaConstantsMatchTheDocumentedExpansionState() {
        // The 0.2.0 release ships event schema v2 (rich content) over
        // index schema v2 (content_hash + preview columns) on archive
        // format v1 — the CHANGELOG and README state these numbers.
        #expect(StoredClipboardEvent.currentSchemaVersion == 2)
        #expect(ClipboardDerivedIndex.currentIndexSchemaVersion == 2)
    }
}
