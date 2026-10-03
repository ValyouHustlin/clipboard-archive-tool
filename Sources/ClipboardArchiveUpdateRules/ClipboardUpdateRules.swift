import Foundation

/// Whether this copy of the app may check for updates, decided from its own
/// Info.plist and nothing else.
///
/// A build made without a feed or a key is a build that never talks to a
/// network. That is the default: `scripts/release.sh` adds the feed and the
/// key only when it is told to.
public enum ClipboardUpdateConfiguration {
    public enum NotConfiguredReason: Sendable, Equatable {
        case noFeed
        case noKey
    }

    public enum RefusalReason: Sendable, Equatable {
        case insecureFeed
        case malformedKey
        case systemProfilingEnabled
        case unsignedFeed
    }

    public enum Outcome: Sendable, Equatable {
        case ready(feedURL: URL)
        case notConfigured(NotConfiguredReason)
        case refused(RefusalReason)

        public var isReady: Bool {
            if case .ready = self { return true }
            return false
        }

        /// One sentence for a person: the updater prints it, the About
        /// section shows it.
        public var sentence: String {
            switch self {
            case .ready(let url):
                return "Updates come from \(url.scheme == "http" ? "a test feed on this Mac" : url.host ?? "the update feed")."
            case .notConfigured(.noFeed):
                return "This copy was built without an update feed, so it never checks for updates."
            case .notConfigured(.noKey):
                return "This copy was built without an update signing key, so it never checks for updates."
            case .refused(.insecureFeed):
                return "The update feed does not use HTTPS, so the updater will not use it."
            case .refused(.malformedKey):
                return "The update signing key in this copy is not a valid Ed25519 public key."
            case .refused(.systemProfilingEnabled):
                return "This copy asks to send a system profile with update checks, which Clipboard Archive never does."
            case .refused(.unsignedFeed):
                return "This copy does not require a signed update feed, so the updater will not use it."
            }
        }
    }

    public static let feedURLKey = "SUFeedURL"
    public static let publicKeyKey = "SUPublicEDKey"
    public static let systemProfilingKey = "SUEnableSystemProfiling"
    public static let requireSignedFeedKey = "SURequireSignedFeed"

    public static func evaluate(infoDictionary info: [String: Any]) -> Outcome {
        let feedString = (info[feedURLKey] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !feedString.isEmpty else {
            return .notConfigured(.noFeed)
        }
        let keyString = (info[publicKeyKey] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !keyString.isEmpty else {
            return .notConfigured(.noKey)
        }

        // HTTPS for anything published. Plain HTTP only to this machine's
        // loopback, so the update path can be driven end to end without a
        // server anywhere (the updater library's downloader refuses file: URLs).
        guard let url = URL(string: feedString), isAcceptableFeed(url) else {
            return .refused(.insecureFeed)
        }
        guard let key = Data(base64Encoded: keyString), key.count == 32 else {
            return .refused(.malformedKey)
        }
        if isTrue(info[systemProfilingKey]) {
            return .refused(.systemProfilingEnabled)
        }
        guard isTrue(info[requireSignedFeedKey]) else {
            return .refused(.unsignedFeed)
        }
        return .ready(feedURL: url)
    }

    private static func isAcceptableFeed(_ url: URL) -> Bool {
        switch url.scheme?.lowercased() {
        case "https":
            return url.host?.isEmpty == false
        case "http":
            return ["127.0.0.1", "localhost"].contains(url.host?.lowercased() ?? "")
        default:
            return false
        }
    }

    private static func isTrue(_ value: Any?) -> Bool {
        switch value {
        case let bool as Bool:
            return bool
        case let number as NSNumber:
            return number.boolValue
        case let string as String:
            return ["yes", "true", "1"].contains(string.lowercased())
        default:
            return false
        }
    }
}

/// Where the helper lives inside the app, and how each finds the other.
public enum ClipboardUpdaterLayout {
    public static let helperBundleName = "Clipboard Archive Updater.app"
    /// The helper is named after the app it ships in, so a test copy with
    /// its own identifier never finds, or is found by, the real helper.
    public static func helperBundleIdentifier(forHost host: String) -> String {
        host + ".updater"
    }

    /// Where the updater keeps its own settings (last check, skipped version):
    /// apart from the app's preferences.
    public static func updaterDefaultsDomain(forHost host: String) -> String {
        host + ".updates"
    }
    /// Posted by the app, observed by its running helper: "check now".
    public static func checkNowNotification(forHost host: String) -> String {
        helperBundleIdentifier(forHost: host) + ".check-now"
    }

    public static func helperURL(inHostApp hostApp: URL) -> URL {
        hostApp
            .appendingPathComponent("Contents", isDirectory: true)
            .appendingPathComponent("Helpers", isDirectory: true)
            .appendingPathComponent(helperBundleName, isDirectory: true)
    }

    /// `<host>.app/Contents/Helpers/<helper>.app` → `<host>.app`, or nil when
    /// the helper is not sitting inside an app bundle.
    public static func hostAppURL(forHelperBundle helper: URL) -> URL? {
        let helpers = helper.deletingLastPathComponent()
        let contents = helpers.deletingLastPathComponent()
        let host = contents.deletingLastPathComponent()
        guard helpers.lastPathComponent == "Helpers",
              contents.lastPathComponent == "Contents",
              host.pathExtension == "app" else {
            return nil
        }
        return host
    }
}

/// What the helper was asked to do.
public enum ClipboardUpdaterMode: Sendable, Equatable {
    /// Started with the app: scheduled checks with the standard windows.
    case background
    /// "Check for Updates…" in the app's menu.
    case checkNow
    /// From a terminal or a script: check, install, report, exit.
    case unattended(verbose: Bool)

    /// nil for anything it does not understand. There is deliberately no
    /// way to point the helper at a different feed from the command line:
    /// the feed is the one the app was built with.
    public static func parse(_ arguments: [String]) -> ClipboardUpdaterMode? {
        let meaningful = arguments.filter { !$0.hasPrefix("-psn_") }
        switch meaningful {
        case []:
            return .background
        case ["--check-now"]:
            return .checkNow
        case ["--unattended"]:
            return .unattended(verbose: false)
        case ["--unattended", "--verbose"], ["--verbose", "--unattended"]:
            return .unattended(verbose: true)
        default:
            return nil
        }
    }
}

/// Exit codes for `--unattended`, in the numbering the command line uses.
public enum ClipboardUpdaterExit: Int32, Sendable {
    case installed = 0
    case failed = 1
    case usage = 2
    case notConfigured = 3
    case refused = 4
    case upToDate = 5
}
