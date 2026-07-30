import Foundation

/// Human-readable explanations for machine blocked-event reasons
/// (Slice 5 dashboard "Recent Blocked Items"). Reasons stay machine-first
/// in the archive; this translates them at display time only.
public enum ClipboardBlockedEventExplainer {
    /// One short sentence for a stored blocked-event `reason`.
    public static func explanation(for reason: String) -> String {
        if let value = value(of: "pasteboard_type_denylist", in: reason) {
            return "The copying app marked this as concealed or transient (\(value))."
        }
        if let value = value(of: "source_app_denylist", in: reason) {
            if ClipboardPrivacyFilter.defaultBlockedBundleIdentifiers.contains(value.lowercased()) {
                return "Built-in password manager protection (\(value))."
            }
            return "App excluded in Settings (\(value))."
        }
        if let value = value(of: "source_app_name_denylist", in: reason) {
            return "App name matches the password manager list (\"\(value)\")."
        }
        if let value = value(of: "app_rule_block", in: reason) {
            return "Blocked by your app privacy rule for \(value)."
        }
        if let value = value(of: "secret_detector", in: reason) {
            let flags = value.split(separator: ",").joined(separator: ", ")
            return "Content looked like a credential (\(flags))."
        }
        return "Blocked: \(reason)"
    }

    /// Short category label for compact surfaces (menu status line).
    public static func shortLabel(for reason: String) -> String {
        if reason.hasPrefix("pasteboard_type_denylist") {
            return "concealed pasteboard type"
        }
        if let value = value(of: "source_app_denylist", in: reason) {
            return ClipboardPrivacyFilter.defaultBlockedBundleIdentifiers.contains(value.lowercased())
                ? "password manager rule"
                : "excluded app"
        }
        if reason.hasPrefix("source_app_name_denylist") {
            return "password manager rule"
        }
        if reason.hasPrefix("app_rule_block") {
            return "app privacy rule"
        }
        if reason.hasPrefix("secret_detector") {
            return "credential detector"
        }
        return "privacy filter"
    }

    private static func value(of prefix: String, in reason: String) -> String? {
        guard reason.hasPrefix(prefix + ":") else {
            return reason == prefix ? "" : nil
        }
        return String(reason.dropFirst(prefix.count + 1))
    }
}
