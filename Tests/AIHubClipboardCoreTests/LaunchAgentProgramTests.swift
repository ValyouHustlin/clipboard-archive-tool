import Foundation
import Testing
@testable import ClipboardArchiveCore

/// A launch agent that hands `open` two apps starts two apps. On 2026-10-03
/// the live agent named both the installed app and a repository build, and
/// `status` read only the first operand, so it called that agent healthy.
@Suite("Launch Agent Program")
struct LaunchAgentProgramTests {
    @Test
    func testOpenWithOneAppNamesOneTarget() {
        let program = ClipboardLaunchAgentProgram.parse(
            program: nil,
            arguments: ["/usr/bin/open", "/Applications/Clipboard Archive.app"]
        )
        #expect(program.targets == ["/Applications/Clipboard Archive.app"])
        #expect(program.primaryPath == "/Applications/Clipboard Archive.app")
    }

    @Test
    func testOpenWithTwoAppsNamesBoth() {
        let program = ClipboardLaunchAgentProgram.parse(
            program: nil,
            arguments: [
                "/usr/bin/open",
                "/Applications/Clipboard Archive.app",
                "/Users/example/repo/dist/ClipboardArchive.app",
            ]
        )
        #expect(program.targets.count == 2)
        #expect(program.primaryPath == "/Applications/Clipboard Archive.app")
    }

    @Test
    func testOpenFlagsAndTheirValuesAreNotTargets() {
        let program = ClipboardLaunchAgentProgram.parse(
            program: nil,
            arguments: [
                "/usr/bin/open", "-g", "-j", "--env", "A=B", "--stdout", "/tmp/out.log",
                "/Applications/Clipboard Archive.app", "--args", "--not-a-target",
            ]
        )
        #expect(program.targets == ["/Applications/Clipboard Archive.app"])
    }

    @Test
    func testOpenByApplicationNameCountsAsATarget() {
        let program = ClipboardLaunchAgentProgram.parse(
            program: nil,
            arguments: ["/usr/bin/open", "-a", "Clipboard Archive", "/Applications/Clipboard Archive.app"]
        )
        #expect(program.targets == ["Clipboard Archive", "/Applications/Clipboard Archive.app"])
    }

    @Test
    func testDirectExecutableIsItsOwnSingleTarget() {
        let direct = ClipboardLaunchAgentProgram.parse(
            program: nil,
            arguments: ["/Applications/Clipboard Archive.app/Contents/MacOS/ClipboardArchive", "--flag"]
        )
        #expect(direct.targets == ["/Applications/Clipboard Archive.app/Contents/MacOS/ClipboardArchive"])

        let programKey = ClipboardLaunchAgentProgram.parse(
            program: "/opt/example/bin/tool",
            arguments: ["ignored-argv0", "/also/ignored"]
        )
        #expect(programKey.targets == ["/opt/example/bin/tool"])
    }

    @Test
    func testNoProgramAtAllHasNoTargets() {
        #expect(ClipboardLaunchAgentProgram.parse(program: nil, arguments: nil).targets.isEmpty)
        #expect(ClipboardLaunchAgentProgram.parse(program: nil, arguments: []).targets.isEmpty)
        #expect(ClipboardLaunchAgentProgram.parse(program: nil, arguments: ["/usr/bin/open"]).targets.isEmpty)
    }

    @Test
    func testStatusWarnsWhenTheAgentWouldStartMoreThanOneApp() {
        var facts = ClipboardStatusFacts(
            storesPresent: true,
            appRunning: true,
            captureEnabled: false,
            heartbeatAge: 10,
            lastCaptureAge: 10,
            errorsLastDay: 0,
            indexState: .fresh
        )
        #expect(ClipboardStatusRules.verdict(facts).isHealthy)

        facts.launchAgentTargetCount = 2
        let verdict = ClipboardStatusRules.verdict(facts)
        #expect(verdict.exit == .warnings)
        #expect(verdict.warnings.contains { $0.contains("names 2 apps") })

        facts.launchAgentTargetCount = 1
        #expect(ClipboardStatusRules.verdict(facts).isHealthy)
    }
}
