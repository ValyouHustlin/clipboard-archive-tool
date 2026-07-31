import Foundation

/// Version and update facts for the Settings "About" section and the CLI
/// (Slice 9). One assembly point so every surface reports the same numbers:
/// app version/build come from the bundle, the format/schema versions come
/// from their owning constants — never re-hardcoded here.
public struct ClipboardVersionInfo: Equatable, Sendable {
    /// The on-disk archive layout version, matching the release
    /// `manifest.json` and the `archive-format.json` marker the writer
    /// stamps at the archive root. Bumped only when the layout changes.
    public static let archiveFormatVersion = 1

    /// The ONE release-page URL constant (local-only contract: the app has
    /// no network code; this string is only copied to the clipboard or
    /// opened in the user's browser on an explicit click. It is narrowly
    /// allowlisted in scripts/check-local-only.sh, mirroring the
    /// https://example.com/ fixture precedent).
    public static let releasePageURLString =
        "https://github.com/ValyouHustlin/clipboard-archive-tool/releases"

    /// The honest update story, verbatim on the About surface.
    public static let updateGuidance =
        "Updates are manual: check the project's GitHub Releases page."

    public var appVersion: String
    public var appBuild: String?
    public var eventSchemaVersion: Int
    public var indexSchemaVersion: Int

    public init(
        appVersion: String,
        appBuild: String? = nil,
        eventSchemaVersion: Int = StoredClipboardEvent.currentSchemaVersion,
        indexSchemaVersion: Int = ClipboardDerivedIndex.currentIndexSchemaVersion
    ) {
        self.appVersion = appVersion
        self.appBuild = appBuild
        self.eventSchemaVersion = eventSchemaVersion
        self.indexSchemaVersion = indexSchemaVersion
    }

    /// The running app's marketing version from the bundle — the SAME
    /// source the Settings About block reports, so the What's New gate and
    /// every display surface agree. Development binaries (no Info.plist)
    /// report the honest "development" literal.
    public static func currentAppVersion(bundle: Bundle = .main) -> String {
        bundle.infoDictionary?["CFBundleShortVersionString"] as? String
            ?? "development"
    }

    /// "Version 0.2.0 (5)" or "Version 0.2.0"; development builds pass the
    /// literal they want shown.
    public var versionDisplay: String {
        guard let appBuild, !appBuild.isEmpty else {
            return "Version \(appVersion)"
        }
        return "Version \(appVersion) (\(appBuild))"
    }

    /// The About block, one string per line, in display order.
    public var summaryLines: [String] {
        [
            versionDisplay,
            "Archive format v\(Self.archiveFormatVersion) · event schema v\(eventSchemaVersion) · search index schema v\(indexSchemaVersion)",
            Self.updateGuidance
        ]
    }
}
