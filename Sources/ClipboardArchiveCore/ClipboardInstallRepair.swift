import Foundation

/// The two decisions that keep one working copy of the app after someone
/// installs a newer one beside an older one (dragging the disk image onto a
/// Mac that still has a release-folder install in `~/Applications`).
///
/// Without them the older copy, started at login, holds the single-instance
/// lock, the newer copy exits the moment it is opened, and login keeps
/// starting the older one. Both decisions are pure so the fast suite covers
/// them; the app only carries them out.
public enum ClipboardInstallRepair {
    /// One copy of the app on disk.
    public struct Copy: Equatable, Sendable {
        /// The `.app` bundle path.
        public var path: String
        public var bundleIdentifier: String?
        /// `CFBundleVersion` as a number, when it is one.
        public var build: Int?

        public init(path: String, bundleIdentifier: String?, build: Int?) {
            self.path = path
            self.bundleIdentifier = bundleIdentifier
            self.build = build
        }
    }

    /// The bundle names a release has installed under.
    public static let knownBundleNames = ["Clipboard Archive.app", "ClipboardArchive.app"]

    /// True when `path` is an app bundle sitting directly in one of the
    /// folders people install into. A copy run from a disk image, from
    /// Downloads, from a build folder or from App Translocation is not
    /// installed, and must never displace or repoint anything.
    public static func isInstalled(_ path: String, installFolders: [String]) -> Bool {
        let url = URL(fileURLWithPath: path).standardizedFileURL
        guard url.pathExtension == "app" else {
            return false
        }
        let parent = url.deletingLastPathComponent().path
        return installFolders
            .map { URL(fileURLWithPath: $0).standardizedFileURL.path }
            .contains(parent)
    }

    /// Whether the copy that was just opened should replace the copy that
    /// holds the single-instance lock. Only a strictly newer build of the
    /// same app, itself installed, takes over; anything uncertain keeps the
    /// old behaviour (the second copy exits).
    public static func shouldTakeOver(own: Copy, holder: Copy?, installFolders: [String]) -> Bool {
        guard let holder,
              let ownIdentifier = own.bundleIdentifier, !ownIdentifier.isEmpty,
              holder.bundleIdentifier == ownIdentifier,
              let ownBuild = own.build, let holderBuild = holder.build,
              ownBuild > holderBuild,
              isInstalled(own.path, installFolders: installFolders) else {
            return false
        }
        let ownPath = URL(fileURLWithPath: own.path).standardizedFileURL.path
        let holderPath = URL(fileURLWithPath: holder.path).standardizedFileURL.path
        return ownPath != holderPath
    }

    /// The outcome of looking at the login item.
    public struct LaunchAgentRepair: Equatable, Sendable {
        /// The file's new bytes.
        public var data: Data
        /// The app path the login item named before.
        public var replacedTarget: String
    }

    /// The login item rewritten to start `own`, or nil when it should be left
    /// alone.
    ///
    /// It is rewritten only when it is an `open`-style agent naming exactly
    /// one app by path, that app is not this copy, and that app is either an
    /// older build of this app or a known bundle name that is no longer
    /// there. Everything else in the file is kept as it was, including the
    /// environment block that pins the data location.
    ///
    /// `describe` answers what is at a path: the copy there, or nil when
    /// nothing is.
    public static func repairedLaunchAgent(
        plist: Data,
        own: Copy,
        installFolders: [String],
        describe: (String) -> Copy?
    ) -> LaunchAgentRepair? {
        guard let ownIdentifier = own.bundleIdentifier, !ownIdentifier.isEmpty,
              let ownBuild = own.build,
              isInstalled(own.path, installFolders: installFolders) else {
            return nil
        }
        var format = PropertyListSerialization.PropertyListFormat.xml
        guard var root = (try? PropertyListSerialization.propertyList(
            from: plist,
            options: [],
            format: &format
        )) as? [String: Any],
              root["Program"] == nil,
              var arguments = root["ProgramArguments"] as? [String],
              let launcher = arguments.first,
              (launcher as NSString).lastPathComponent == "open" else {
            return nil
        }

        let targets = ClipboardLaunchAgentProgram.parse(program: nil, arguments: arguments).targets
        guard targets.count == 1, let target = targets.first, target.hasPrefix("/") else {
            return nil
        }
        let ownPath = URL(fileURLWithPath: own.path).standardizedFileURL.path
        guard URL(fileURLWithPath: target).standardizedFileURL.path != ownPath else {
            return nil
        }

        if let other = describe(target) {
            // Another copy is there. Repoint only away from an older build
            // of this same app, never away from a newer one or another app.
            guard other.bundleIdentifier == ownIdentifier,
                  let otherBuild = other.build, otherBuild < ownBuild else {
                return nil
            }
        } else {
            // Nothing is there. Repoint only when the name is one a release
            // of this app installed under.
            guard knownBundleNames.contains((target as NSString).lastPathComponent) else {
                return nil
            }
        }

        // The target is a plain operand, so it appears exactly once outside
        // any option's value; replace that one argument.
        guard let index = arguments.lastIndex(of: target) else {
            return nil
        }
        arguments[index] = ownPath
        root["ProgramArguments"] = arguments
        guard let data = try? PropertyListSerialization.data(
            fromPropertyList: root,
            format: .xml,
            options: 0
        ) else {
            return nil
        }
        return LaunchAgentRepair(data: data, replacedTarget: target)
    }
}
