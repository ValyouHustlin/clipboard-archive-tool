import Foundation

/// Pure decision logic for the post-upgrade "What's New" window. The UI
/// layer owns presentation and persistence; every launch-time decision runs
/// through this one function so the table test in `WhatsNewTests` covers
/// the whole matrix.
public enum ClipboardWhatsNew {
    /// Whether the launch flow should present the What's New window.
    ///
    /// Rules:
    /// - Never while first-run onboarding is incomplete (that flow presents
    ///   the same window itself as an optional second step).
    /// - Never for an empty current version (nothing meaningful to stamp).
    /// - Once per version: an empty `lastSeenVersion` means "never shown"
    ///   (including settings files written by builds without the key), so
    ///   existing users see it exactly once after upgrading; after the
    ///   presenter persists the current version, the decision stays false
    ///   until the version changes again.
    public static func shouldShow(
        hasCompletedOnboarding: Bool,
        lastSeenVersion: String,
        currentVersion: String
    ) -> Bool {
        guard hasCompletedOnboarding, !currentVersion.isEmpty else {
            return false
        }
        return lastSeenVersion != currentVersion
    }
}
