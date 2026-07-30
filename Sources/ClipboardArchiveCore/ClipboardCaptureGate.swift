import Foundation

/// Pure capture-loop gating for timed private mode and pause (Slice 5).
///
/// The menu bar app's poll loop consults this BEFORE reading the
/// pasteboard, so during private mode nothing is evaluated, stored, or
/// even recorded as a blocked-event metadata line — guaranteed
/// structurally, not by filtering.
///
/// It also owns the exit rule that fixes the pre-existing pause
/// retro-capture privacy bug: the FIRST poll after private mode or a pause
/// ends must RESYNC the dedup state (`lastChangeCount`/`lastContentHash`)
/// from the current pasteboard WITHOUT ingesting. Without the resync, the
/// last item copied during the gap is captured retroactively on resume.
public enum ClipboardCaptureGate {
    public enum Decision: Equatable, Sendable {
        /// Private mode: return before touching the pasteboard.
        case skipPrivateMode
        /// Paused (manual or timed): return before ingesting.
        case skipPaused
        /// The gate JUST lifted: sync dedup state from the current
        /// pasteboard without ingesting, then wait for the next change.
        case resyncWithoutIngesting
        /// Capture normally.
        case proceed
    }

    /// One poll decision. `wasGatedLastPoll` is whether the PREVIOUS poll
    /// returned a skip decision (the caller stores this); it drives the
    /// one-time exit resync.
    public static func decision(
        now: Date,
        privateModeUntil: Date?,
        pauseUntil: Date?,
        manuallyPaused: Bool,
        wasGatedLastPoll: Bool
    ) -> Decision {
        if let privateModeUntil, privateModeUntil > now {
            return .skipPrivateMode
        }
        if manuallyPaused || (pauseUntil.map { $0 > now } ?? false) {
            return .skipPaused
        }
        if wasGatedLastPoll {
            return .resyncWithoutIngesting
        }
        return .proceed
    }
}
