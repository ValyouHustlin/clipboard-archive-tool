import Foundation

public enum ClipboardFilterDecision: Equatable, Sendable {
    case allow(sensitivityFlags: [String])
    case block(reason: String)
}

public struct ClipboardPrivacyFilter: Sendable {
    public var blockedBundleIdentifiers: Set<String>
    public var blockedAppNameFragments: [String]
    public var secretDetector: SecretDetector

    public init(
        blockedBundleIdentifiers: Set<String> = ClipboardPrivacyFilter.defaultBlockedBundleIdentifiers,
        blockedAppNameFragments: [String] = ClipboardPrivacyFilter.defaultBlockedAppNameFragments,
        secretDetector: SecretDetector = SecretDetector()
    ) {
        self.blockedBundleIdentifiers = blockedBundleIdentifiers
        self.blockedAppNameFragments = blockedAppNameFragments
        self.secretDetector = secretDetector
    }

    public init(settings: ClipboardSettings, secretDetector: SecretDetector = SecretDetector()) {
        self.blockedBundleIdentifiers = ClipboardPrivacyFilter.defaultBlockedBundleIdentifiers
            .union(settings.excludedBundleIdentifiers.map { $0.lowercased() })
        self.blockedAppNameFragments = ClipboardPrivacyFilter.defaultBlockedAppNameFragments
            + settings.excludedAppNameFragments.map { $0.lowercased() }
        self.secretDetector = secretDetector
    }

    public func evaluate(_ capture: ClipboardCapture) -> ClipboardFilterDecision {
        if let bundleIdentifier = capture.sourceApp.bundleIdentifier,
           blockedBundleIdentifiers.contains(bundleIdentifier.lowercased()) {
            return .block(reason: "source_app_denylist:\(bundleIdentifier)")
        }

        let appName = capture.sourceApp.name.lowercased()
        if let fragment = blockedAppNameFragments.first(where: { appName.contains($0) }) {
            return .block(reason: "source_app_name_denylist:\(fragment)")
        }

        let detection = secretDetector.inspect(capture.content)
        if detection.isSensitive {
            let flags = detection.flags.joined(separator: ",")
            return .block(reason: "secret_detector:\(flags)")
        }

        return .allow(sensitivityFlags: [])
    }

    public static let defaultBlockedBundleIdentifiers: Set<String> = [
        "com.dashlane.dashlane",
        "com.1password.1password",
        "com.1password.1password7",
        "com.apple.passwords",
        "com.apple.keychainaccess"
    ]

    public static let defaultBlockedAppNameFragments: [String] = [
        "dashlane",
        "1password",
        "onepassword",
        "passwords",
        "keychain access"
    ]
}
