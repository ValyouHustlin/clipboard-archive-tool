import Foundation

public struct SecretDetection: Equatable, Sendable {
    public var isSensitive: Bool
    public var flags: [String]
}

public struct SecretDetector: Sendable {
    private let regexes: [(flag: String, regex: NSRegularExpression)]

    public init() {
        let patterns: [(String, String)] = [
            ("private-key", #"-----BEGIN [A-Z ]*PRIVATE KEY-----"#),
            ("github-token", #"gh[pousr]_[A-Za-z0-9_]{20,}"#),
            ("openai-token", #"sk-[A-Za-z0-9_-]{20,}"#),
            ("aws-access-key", #"AKIA[0-9A-Z]{16}"#),
            ("jwt", #"\beyJ[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\b"#),
            ("env-secret-assignment", #"(?i)\b[A-Z0-9_ -]{0,40}(API|ACCESS|AUTH|CLIENT|PRIVATE|SECRET|TOKEN|PASSWORD|PASS|KEY)[A-Z0-9_ -]{0,40}=\S{8,}"#),
            ("recovery-code", #"(?i)\b(recovery|backup)[ _-]?code[:= ]+[A-Z0-9 -]{8,}"#)
        ]

        self.regexes = patterns.compactMap { flag, pattern in
            guard let regex = try? NSRegularExpression(pattern: pattern) else {
                return nil
            }
            return (flag, regex)
        }
    }

    public func inspect(_ text: String) -> SecretDetection {
        var flags: [String] = []
        let range = NSRange(text.startIndex..<text.endIndex, in: text)

        for item in regexes {
            if item.regex.firstMatch(in: text, range: range) != nil {
                flags.append(item.flag)
            }
        }

        if looksLikeSingleHighEntropySecret(text) {
            flags.append("single-high-entropy-value")
        }

        return SecretDetection(isSensitive: !flags.isEmpty, flags: flags)
    }

    private func looksLikeSingleHighEntropySecret(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 32, trimmed.count <= 256 else {
            return false
        }
        guard trimmed.rangeOfCharacter(from: .whitespacesAndNewlines) == nil else {
            return false
        }

        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_+=/.")
        guard trimmed.unicodeScalars.allSatisfy({ allowed.contains($0) }) else {
            return false
        }

        let uniqueRatio = Double(Set(trimmed).count) / Double(trimmed.count)
        return uniqueRatio > 0.45
    }
}
