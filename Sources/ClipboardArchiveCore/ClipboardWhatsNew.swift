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
    /// - Only when the window has something this user has not seen. Its
    ///   content describes the features up to `highlightsVersion`; someone
    ///   already on that version or later has seen it, and showing the same
    ///   list after every later update told them nothing new.
    public static func shouldShow(
        hasCompletedOnboarding: Bool,
        lastSeenVersion: String,
        currentVersion: String
    ) -> Bool {
        guard hasCompletedOnboarding, !currentVersion.isEmpty else {
            return false
        }
        guard lastSeenVersion != currentVersion else {
            return false
        }
        guard let seen = numericVersion(lastSeenVersion),
              let highlights = numericVersion(highlightsVersion) else {
            // Never shown, or a version that is not a number (a development
            // build): show it once.
            return true
        }
        return seen.lexicographicallyPrecedes(highlights)
    }

    /// The newest version whose features the window describes. Raise it
    /// when the window's content is rewritten for a later release.
    public static let highlightsVersion = "0.3.0"

    private static func numericVersion(_ version: String) -> [Int]? {
        let parts = version.split(separator: ".").map { Int($0) }
        guard !parts.isEmpty, !parts.contains(nil) else {
            return nil
        }
        return parts.compactMap { $0 }
    }
}
