import Foundation

/// Why a clip did not make it into an export file.
public enum ClipboardExportExclusion: String, Sendable, Codable {
    /// Deleted, or carrying the tombstone label redaction writes.
    case suppressed
    /// Labelled restricted when it was captured.
    case restricted
    /// Marked restricted by hand afterwards, which applies to every copy of
    /// the same content.
    case manuallyRestricted
}

/// The one rule that decides what an export file may hold.
///
/// An export writes real clipboard content to a file, so the rule is written
/// once, here, and both the writer and its tests use it. It is deliberately
/// stricter than what the history window shows: a clip that is visible in
/// the app but is marked sensitive does not leave the machine in a file.
public enum ClipboardExportRules {
    public static func exclusion(
        for event: StoredClipboardEvent,
        suppression: ClipboardSuppression.Snapshot,
        sensitivityOverride: String?
    ) -> ClipboardExportExclusion? {
        if suppression.isSuppressed(event) {
            return .suppressed
        }
        if event.privacyLabel == .restricted {
            return .restricted
        }
        if sensitivityOverride == "restricted" {
            return .manuallyRestricted
        }
        return nil
    }

    public static func isExportable(
        _ event: StoredClipboardEvent,
        suppression: ClipboardSuppression.Snapshot,
        sensitivityOverride: String?
    ) -> Bool {
        exclusion(for: event, suppression: suppression, sensitivityOverride: sensitivityOverride) == nil
    }

    /// Owner read/write and nothing else: an export file is as sensitive as
    /// the clips in it.
    public static let filePermissions: Int16 = 0o600
}
