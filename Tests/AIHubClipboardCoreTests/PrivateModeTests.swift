import Foundation
import Testing
@testable import ClipboardArchiveCore

/// Slice 5 timed private mode + the pause retro-capture fix. The capture
/// gate is the pure decision core the menu bar app's poll loop consults
/// BEFORE reading the pasteboard; these tests drive a simulated pasteboard
/// through it to prove nothing is stored or blocked during a gap and that
/// the exit resync prevents retro-capture (the pre-existing pause privacy
/// bug fixed in this slice).
@Suite("Private Mode")
struct PrivateModeTests {
    /// Minimal simulation of the app's poll loop dedup state driven by the
    /// gate: mirrors main.swift's pollPasteboard structure.
    private struct SimulatedPoller {
        var lastChangeCount: Int
        var lastContentHash: Int?
        var wasGatedLastPoll = false
        var storedContents: [String] = []

        mutating func poll(
            now: Date,
            pasteboardChangeCount: Int,
            pasteboardContent: String?,
            privateModeUntil: Date?,
            pauseUntil: Date?,
            manuallyPaused: Bool
        ) {
            let decision = ClipboardCaptureGate.decision(
                now: now,
                privateModeUntil: privateModeUntil,
                pauseUntil: pauseUntil,
                manuallyPaused: manuallyPaused,
                wasGatedLastPoll: wasGatedLastPoll
            )
            switch decision {
            case .skipPrivateMode, .skipPaused:
                wasGatedLastPoll = true
                return
            case .resyncWithoutIngesting:
                wasGatedLastPoll = false
                lastChangeCount = pasteboardChangeCount
                lastContentHash = pasteboardContent?.hashValue
                return
            case .proceed:
                wasGatedLastPoll = false
            }
            guard pasteboardChangeCount != lastChangeCount else {
                return
            }
            lastChangeCount = pasteboardChangeCount
            guard let pasteboardContent, !pasteboardContent.isEmpty else {
                return
            }
            let hash = pasteboardContent.hashValue
            guard hash != lastContentHash else {
                return
            }
            lastContentHash = hash
            storedContents.append(pasteboardContent)
        }
    }

    @Test func testPrivateModeSkipsBeforePasteboardRead() throws {
        let now = Date()
        let decision = ClipboardCaptureGate.decision(
            now: now,
            privateModeUntil: now.addingTimeInterval(900),
            pauseUntil: nil,
            manuallyPaused: false,
            wasGatedLastPoll: false
        )
        #expect(decision == .skipPrivateMode)
    }

    @Test func testPrivateModeBeatsPauseInDecisionOrder() throws {
        let now = Date()
        let decision = ClipboardCaptureGate.decision(
            now: now,
            privateModeUntil: now.addingTimeInterval(900),
            pauseUntil: now.addingTimeInterval(900),
            manuallyPaused: true,
            wasGatedLastPoll: true
        )
        #expect(decision == .skipPrivateMode)
    }

    @Test func testExpiredPrivateModeTriggersOneResyncThenProceeds() throws {
        let now = Date()
        let afterGap = ClipboardCaptureGate.decision(
            now: now,
            privateModeUntil: now.addingTimeInterval(-1),
            pauseUntil: nil,
            manuallyPaused: false,
            wasGatedLastPoll: true
        )
        #expect(afterGap == .resyncWithoutIngesting)
        let next = ClipboardCaptureGate.decision(
            now: now,
            privateModeUntil: now.addingTimeInterval(-1),
            pauseUntil: nil,
            manuallyPaused: false,
            wasGatedLastPoll: false
        )
        #expect(next == .proceed)
    }

    @Test func testNothingStoredDuringPrivateModeAndNoRetroCaptureOnExit() throws {
        let start = Date()
        var poller = SimulatedPoller(lastChangeCount: 0, lastContentHash: nil)
        let privateUntil = start.addingTimeInterval(900)

        // Copy twice DURING private mode: nothing stored, nothing evaluated.
        poller.poll(now: start.addingTimeInterval(10), pasteboardChangeCount: 1,
                    pasteboardContent: "private secret one",
                    privateModeUntil: privateUntil, pauseUntil: nil, manuallyPaused: false)
        poller.poll(now: start.addingTimeInterval(20), pasteboardChangeCount: 2,
                    pasteboardContent: "private secret two",
                    privateModeUntil: privateUntil, pauseUntil: nil, manuallyPaused: false)
        #expect(poller.storedContents.isEmpty)

        // First poll after expiry: resync only — the LAST thing copied
        // during private mode is NEVER retro-captured.
        poller.poll(now: start.addingTimeInterval(1_000), pasteboardChangeCount: 2,
                    pasteboardContent: "private secret two",
                    privateModeUntil: privateUntil, pauseUntil: nil, manuallyPaused: false)
        #expect(poller.storedContents.isEmpty)

        // Steady state after resync: still nothing (no change count bump).
        poller.poll(now: start.addingTimeInterval(1_010), pasteboardChangeCount: 2,
                    pasteboardContent: "private secret two",
                    privateModeUntil: privateUntil, pauseUntil: nil, manuallyPaused: false)
        #expect(poller.storedContents.isEmpty)

        // A NEW copy after resume captures normally.
        poller.poll(now: start.addingTimeInterval(1_020), pasteboardChangeCount: 3,
                    pasteboardContent: "post-private ordinary copy",
                    privateModeUntil: privateUntil, pauseUntil: nil, manuallyPaused: false)
        #expect(poller.storedContents == ["post-private ordinary copy"])
    }

    /// The pre-existing pause privacy bug, fixed the same way: without the
    /// exit resync, the item copied during the pause was captured
    /// retroactively on resume.
    @Test func testPauseExitResyncPreventsRetroCapture() throws {
        let start = Date()
        var poller = SimulatedPoller(lastChangeCount: 0, lastContentHash: nil)
        let pauseUntil = start.addingTimeInterval(900)

        poller.poll(now: start.addingTimeInterval(5), pasteboardChangeCount: 1,
                    pasteboardContent: "copied during pause",
                    privateModeUntil: nil, pauseUntil: pauseUntil, manuallyPaused: false)
        #expect(poller.storedContents.isEmpty)

        // Pause expired → resync poll, then steady polls: never captured.
        poller.poll(now: start.addingTimeInterval(1_000), pasteboardChangeCount: 1,
                    pasteboardContent: "copied during pause",
                    privateModeUntil: nil, pauseUntil: pauseUntil, manuallyPaused: false)
        poller.poll(now: start.addingTimeInterval(1_010), pasteboardChangeCount: 1,
                    pasteboardContent: "copied during pause",
                    privateModeUntil: nil, pauseUntil: pauseUntil, manuallyPaused: false)
        #expect(poller.storedContents.isEmpty)

        poller.poll(now: start.addingTimeInterval(1_020), pasteboardChangeCount: 2,
                    pasteboardContent: "fresh copy after resume",
                    privateModeUntil: nil, pauseUntil: pauseUntil, manuallyPaused: false)
        #expect(poller.storedContents == ["fresh copy after resume"])
    }

    @Test func testManualPauseGetsTheSameExitResync() throws {
        let now = Date()
        // Manual pause active.
        #expect(ClipboardCaptureGate.decision(
            now: now, privateModeUntil: nil, pauseUntil: nil,
            manuallyPaused: true, wasGatedLastPoll: false
        ) == .skipPaused)
        // Manual pause lifted → one resync poll.
        #expect(ClipboardCaptureGate.decision(
            now: now, privateModeUntil: nil, pauseUntil: nil,
            manuallyPaused: false, wasGatedLastPoll: true
        ) == .resyncWithoutIngesting)
    }

    @Test func testSettingsPrivateModeStateAndPersistence() throws {
        var settings = ClipboardSettings()
        #expect(!settings.isPrivateModeActive)
        settings.privateModeUntil = Date().addingTimeInterval(900)
        #expect(settings.isPrivateModeActive)
        settings.privateModeUntil = Date().addingTimeInterval(-1)
        #expect(!settings.isPrivateModeActive)
    }
}
