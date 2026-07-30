import Foundation

public enum ClipboardFilterDecision: Equatable, Sendable {
    case allow(sensitivityFlags: [String])
    /// Per-app `store-no-index` rule matched: the capture is archived with
    /// `privacyLabel: .restricted` (+ flag `app-rule-no-index`) and never
    /// enters the derived search index. Stored, visible, never searchable.
    case allowStoreNoIndex(sensitivityFlags: [String], ruleBundleID: String)
    case block(reason: String)
}

/// Capture-time privacy filter. Evaluation precedence (Slice 5, fixture-
/// tested — the order is a privacy contract, not an implementation detail):
///
/// 1. Pasteboard-type denylist (concealed/transient/password-manager types).
///    NOTHING overrides this — the copying app explicitly marked the data.
/// 2. Built-in password-manager lists (bundle ids + app-name fragments).
///    A "normal" per-app rule CANNOT override these; the Settings UI says so.
/// 3. Explicit per-app privacy rules (`appPrivacyRules`, lowercased bundle
///    keys): `block` → blocked with reason `app_rule_block:<bundleid>`;
///    `store-no-index` → stored restricted, never indexed; `normal` →
///    proceeds to the secret detector (bypassing the legacy lists);
///    UNKNOWN modes evaluate as block (fail closed).
/// 4. Legacy user exclusion lists (`excludedBundleIdentifiers` /
///    `excludedAppNameFragments`) — consulted only when the app has NO
///    explicit rule.
/// 5. Secret detector (content inspection). Runs for every capture that
///    survives 1–4, including `store-no-index` apps: an app rule about
///    indexing never weakens credential blocking.
public struct ClipboardPrivacyFilter: Sendable {
    /// Built-in protection lists (precedence 2). Kept separate from the
    /// user's legacy lists so an explicit "normal" rule can bypass the
    /// legacy lists (4) but never the built-ins.
    public var builtinBlockedBundleIdentifiers: Set<String>
    public var builtinBlockedAppNameFragments: [String]
    /// Legacy user exclusion lists (precedence 4).
    public var userExcludedBundleIdentifiers: Set<String>
    public var userExcludedAppNameFragments: [String]
    public var blockedPasteboardTypes: Set<String>
    /// Explicit per-app rules keyed by lowercased bundle id (precedence 3).
    public var appPrivacyRules: [String: ClipboardAppPrivacyRule]
    public var secretDetector: SecretDetector

    /// Legacy accessors preserved for existing call sites and tests: the
    /// combined view of built-in plus user lists.
    public var blockedBundleIdentifiers: Set<String> {
        builtinBlockedBundleIdentifiers.union(userExcludedBundleIdentifiers)
    }

    public var blockedAppNameFragments: [String] {
        builtinBlockedAppNameFragments + userExcludedAppNameFragments
    }

    public init(
        blockedBundleIdentifiers: Set<String> = ClipboardPrivacyFilter.defaultBlockedBundleIdentifiers,
        blockedAppNameFragments: [String] = ClipboardPrivacyFilter.defaultBlockedAppNameFragments,
        blockedPasteboardTypes: Set<String> = ClipboardPrivacyFilter.defaultBlockedPasteboardTypes,
        appPrivacyRules: [String: ClipboardAppPrivacyRule] = [:],
        secretDetector: SecretDetector = SecretDetector()
    ) {
        self.builtinBlockedBundleIdentifiers = blockedBundleIdentifiers
        self.builtinBlockedAppNameFragments = blockedAppNameFragments
        self.userExcludedBundleIdentifiers = []
        self.userExcludedAppNameFragments = []
        self.blockedPasteboardTypes = blockedPasteboardTypes
        self.appPrivacyRules = ClipboardSettings.normalizedRuleKeys(appPrivacyRules)
        self.secretDetector = secretDetector
    }

    public init(settings: ClipboardSettings, secretDetector: SecretDetector = SecretDetector()) {
        self.builtinBlockedBundleIdentifiers = ClipboardPrivacyFilter.defaultBlockedBundleIdentifiers
        self.builtinBlockedAppNameFragments = ClipboardPrivacyFilter.defaultBlockedAppNameFragments
        self.userExcludedBundleIdentifiers = Set(settings.excludedBundleIdentifiers.map { $0.lowercased() })
        self.userExcludedAppNameFragments = settings.excludedAppNameFragments.map { $0.lowercased() }
        self.blockedPasteboardTypes = ClipboardPrivacyFilter.defaultBlockedPasteboardTypes
        self.appPrivacyRules = ClipboardSettings.normalizedRuleKeys(settings.appPrivacyRules)
        self.secretDetector = secretDetector
    }

    public func evaluate(_ capture: ClipboardCapture) -> ClipboardFilterDecision {
        // 1. Pasteboard-type denylist — no override, ever.
        if let confidentialType = capture.pasteboardTypes.first(where: {
            blockedPasteboardTypes.contains($0.lowercased())
        }) {
            return .block(reason: "pasteboard_type_denylist:\(confidentialType)")
        }

        let bundleIdentifier = capture.sourceApp.bundleIdentifier?.lowercased()
        let appName = capture.sourceApp.name.lowercased()

        // 2. Built-in password-manager protection — a "normal" rule cannot
        //    override this tier.
        if let bundleIdentifier, builtinBlockedBundleIdentifiers.contains(bundleIdentifier) {
            return .block(reason: "source_app_denylist:\(bundleIdentifier)")
        }
        if let fragment = builtinBlockedAppNameFragments.first(where: { appName.contains($0) }) {
            return .block(reason: "source_app_name_denylist:\(fragment)")
        }

        // 3. Explicit per-app rules (unknown mode = block, fail closed).
        var explicitRule: ClipboardAppPrivacyRule?
        if let bundleIdentifier, let rule = appPrivacyRules[bundleIdentifier] {
            explicitRule = rule
            if rule.evaluatesAsBlock {
                return .block(reason: "app_rule_block:\(bundleIdentifier)")
            }
        }

        // 4. Legacy exclusion lists — only when no explicit rule exists.
        if explicitRule == nil {
            if let bundleIdentifier, userExcludedBundleIdentifiers.contains(bundleIdentifier) {
                return .block(reason: "source_app_denylist:\(bundleIdentifier)")
            }
            if let fragment = userExcludedAppNameFragments.first(where: { appName.contains($0) }) {
                return .block(reason: "source_app_name_denylist:\(fragment)")
            }
        }

        // 5. Secret detector — runs even for store-no-index apps. It always
        //    inspects the plain fallback (rtf fallback, link url+title,
        //    file-list joined paths, color hex — Slice 6).
        var detection = secretDetector.inspect(capture.content)
        if case .fileList = capture.rich {
            // File paths are structurally single high-entropy tokens, so
            // the bare-token entropy heuristic would block ordinary
            // single-file copies. Pattern-based flags (tokens/keys INSIDE a
            // path or file name) still block.
            let flags = detection.flags.filter { $0 != "single-high-entropy-value" }
            detection = SecretDetection(isSensitive: !flags.isEmpty, flags: flags)
        }
        if detection.isSensitive {
            let flags = detection.flags.joined(separator: ",")
            return .block(reason: "secret_detector:\(flags)")
        }

        if let explicitRule, explicitRule.isStoreNoIndex, let bundleIdentifier {
            return .allowStoreNoIndex(sensitivityFlags: [], ruleBundleID: bundleIdentifier)
        }
        return .allow(sensitivityFlags: [])
    }

    public static let defaultBlockedBundleIdentifiers: Set<String> = [
        "com.dashlane.dashlane",
        "com.1password.1password",
        "com.1password.1password7",
        "com.bitwarden.desktop",
        "com.lastpass.lastpass",
        "org.keepassxc.keepassxc",
        "com.protonpass.macos",
        "com.enpass.desktop",
        "com.callasign.keeper",
        "com.nordpass.macos",
        "com.siber.roboform",
        "com.strongbox",
        "com.apple.passwords",
        "com.apple.keychainaccess"
    ]

    public static let defaultBlockedAppNameFragments: [String] = [
        "dashlane",
        "1password",
        "onepassword",
        "bitwarden",
        "lastpass",
        "keepass",
        "proton pass",
        "enpass",
        "keeper",
        "nordpass",
        "roboform",
        "strongbox",
        "passwords",
        "keychain access"
    ]

    public static let defaultBlockedPasteboardTypes: Set<String> = [
        "org.nspasteboard.transienttype",
        "org.nspasteboard.concealedtype",
        "org.nspasteboard.autogeneratedtype",
        "com.agilebits.onepassword",
        "de.petermaurer.transientpasteboardtype",
        "pasteboard generator type"
    ]
}
