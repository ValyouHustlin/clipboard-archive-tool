import Foundation

/// Pure clip transformations (Slice 7, feature matrix row 7).
///
/// Deliberately AppKit-free: every function is a total `String -> String`
/// map with no throwing paths, no pasteboard access, and no archive access.
/// The transformation layer works on the stored PLAIN-TEXT content — for
/// rich events that plain fallback was already derived at capture time
/// (RTF/link/color events store it inline; images store an empty fallback),
/// so nothing here ever needs to parse a rich body.
///
/// Copy surfaces apply a transformation and then route the result through
/// the app delegate's shared no-re-capture plain-text copy path — never a
/// direct pasteboard write, and never a write back into the archive.
public enum ClipTransformations {
    // MARK: - Plain text

    /// Plain-text form of stored clip content. The rich-to-plain reduction
    /// happened at capture (the stored fallback IS the plain text), so this
    /// only normalizes the line-break zoo some sources embed in that
    /// fallback: CRLF/CR and Unicode line/paragraph separators become `\n`,
    /// and invisible attachment placeholders (U+FFFC) are dropped.
    public static func plainText(from content: String) -> String {
        var value = content
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .replacingOccurrences(of: "\u{2028}", with: "\n")
            .replacingOccurrences(of: "\u{2029}", with: "\n")
        value.removeAll { $0 == "\u{FFFC}" }
        return value
    }

    // MARK: - Strip formatting

    /// Normalizes typographic punctuation to ASCII and strips invisible
    /// formatting characters:
    /// - smart single quotes → `'`, smart double quotes/guillemets → `"`
    /// - en/em/figure/horizontal-bar dashes and Unicode minus → `-`
    /// - ellipsis → `...`
    /// - zero-width characters (ZWSP, ZWNJ, WJ, BOM) and soft hyphens are
    ///   removed
    /// - directional controls (LRM/RLM, LRE/RLE/PDF/LRO/RLO, LRI/RLI/FSI/
    ///   PDI) are removed — the visible RTL text itself is untouched
    /// - ZWJ (U+200D) is removed EXCEPT between emoji scalars, so emoji
    ///   family/profession sequences survive intact.
    public static func stripFormatting(_ text: String) -> String {
        let scalars = Array(text.unicodeScalars)
        var result = String.UnicodeScalarView()
        result.reserveCapacity(scalars.count)
        for (index, scalar) in scalars.enumerated() {
            switch scalar.value {
            case 0x2018, 0x2019, 0x201A, 0x201B:
                result.append("'")
            case 0x201C, 0x201D, 0x201E, 0x201F, 0x00AB, 0x00BB:
                result.append("\"")
            case 0x2010, 0x2011, 0x2012, 0x2013, 0x2014, 0x2015, 0x2212:
                result.append("-")
            case 0x2026:
                result.append(contentsOf: "...".unicodeScalars)
            case 0x200B, 0x200C, 0x2060, 0xFEFF, 0x00AD:
                continue // zero-width / soft hyphen: strip
            case 0x200E, 0x200F, 0x202A...0x202E, 0x2066...0x2069:
                continue // directional controls: strip
            case 0x200D:
                // ZWJ: keep only when it joins an emoji sequence (both
                // neighbors are emoji-property scalars or a variation
                // selector), so 👨‍👩‍👧 stays a family and text ZWJs vanish.
                let previous = index > 0 ? scalars[index - 1] : nil
                let next = index + 1 < scalars.count ? scalars[index + 1] : nil
                func joinsEmoji(_ neighbor: Unicode.Scalar?) -> Bool {
                    guard let neighbor else {
                        return false
                    }
                    return neighbor.properties.isEmoji || neighbor.value == 0xFE0F
                }
                if joinsEmoji(previous), joinsEmoji(next) {
                    result.append(scalar)
                }
            default:
                result.append(scalar)
            }
        }
        return String(result)
    }

    // MARK: - URL tracking cleanup

    /// The tracking query parameters `cleanURL` removes (exact names,
    /// compared case-insensitively). `utm_*` is handled by prefix via
    /// `trackingParameterPrefixes`.
    public static let trackingParameterNames: Set<String> = [
        "fbclid", "gclid", "gbraid", "wbraid", "msclkid", "mc_eid",
        "igshid", "si", "ref_src", "vero_id", "yclid", "twclid"
    ]

    /// Tracking parameter name prefixes (covers utm_source, utm_medium,
    /// utm_campaign, utm_term, utm_content, and any future utm_* key).
    public static let trackingParameterPrefixes: [String] = ["utm_"]

    /// Removes known tracking parameters from every URL found in `text`.
    ///
    /// Guarantees:
    /// - everything outside a URL's query string is preserved byte-for-byte
    ///   (fragments, paths, percent-encoding, non-URL text, ampersands in
    ///   prose);
    /// - surviving query parameters keep their original order AND their
    ///   original bytes (no re-encoding);
    /// - a URL whose query becomes empty loses the `?` as well;
    /// - a URL that carries no tracking parameters is returned untouched;
    /// - trailing sentence punctuation glued to a URL (`).`, `,` …) is never
    ///   treated as part of the query.
    ///
    /// URL detection is scheme-shaped (`scheme://non-space run`) rather than
    /// a hardcoded scheme list, so the function stays total on arbitrary
    /// text and this local-only codebase embeds no web URL literals.
    public static func cleanURL(_ text: String) -> String {
        guard text.contains("://"), text.contains("?") else {
            return text
        }
        guard let regex = Self.urlRegex else {
            return text
        }
        let nsText = text as NSString
        let matches = regex.matches(
            in: text,
            range: NSRange(location: 0, length: nsText.length)
        )
        guard !matches.isEmpty else {
            return text
        }
        var result = ""
        var cursor = 0
        for match in matches {
            let range = match.range
            result += nsText.substring(
                with: NSRange(location: cursor, length: range.location - cursor)
            )
            result += cleanedURLToken(nsText.substring(with: range))
            cursor = range.location + range.length
        }
        result += nsText.substring(from: cursor)
        return result
    }

    private static let urlRegex = try? NSRegularExpression(
        pattern: "[A-Za-z][A-Za-z0-9+.-]*://[^\\s<>\"'`]+"
    )

    /// Sentence punctuation commonly glued to the end of a pasted URL.
    private static let urlTrailingPunctuation = Set<Character>(
        [".", ",", ";", ":", "!", "?", ")", "]", "}", "'", "\"", ">"]
    )

    private static func cleanedURLToken(_ token: String) -> String {
        // Split off trailing sentence punctuation so "(…?fbclid=1)." keeps
        // its ")." after cleaning. The trailer is reattached untouched.
        var core = token
        var trailer = ""
        while let last = core.last, urlTrailingPunctuation.contains(last) {
            trailer.insert(last, at: trailer.startIndex)
            core.removeLast()
        }
        guard let questionIndex = core.firstIndex(of: "?") else {
            return token
        }
        let hashIndex = core.firstIndex(of: "#")
        if let hashIndex, hashIndex < questionIndex {
            // The only "?" sits inside the fragment — nothing to clean.
            return token
        }
        let base = core[..<questionIndex]
        let queryEnd = hashIndex ?? core.endIndex
        let query = core[core.index(after: questionIndex)..<queryEnd]
        let fragment = hashIndex.map { String(core[$0...]) } ?? ""

        let pieces = query.split(separator: "&", omittingEmptySubsequences: false)
        let survivors = pieces.filter { !isTrackingParameter($0) }
        guard survivors.count != pieces.count else {
            return token // nothing removed: byte-for-byte original
        }
        let cleanedQuery = survivors.joined(separator: "&")
        let rebuilt = cleanedQuery.isEmpty
            ? base + fragment
            : base + "?" + cleanedQuery + fragment
        return rebuilt + trailer
    }

    private static func isTrackingParameter(_ piece: Substring) -> Bool {
        let name = piece.prefix { $0 != "=" }.lowercased()
        guard !name.isEmpty else {
            return false
        }
        if trackingParameterNames.contains(name) {
            return true
        }
        return trackingParameterPrefixes.contains { name.hasPrefix($0) }
    }

    // MARK: - Whitespace normalization

    /// Normalizes whitespace, idempotently (`f(f(s)) == f(s)`):
    /// - CRLF/CR line endings become `\n`
    /// - runs of spaces/tabs collapse to a single space
    /// - line-trailing whitespace is trimmed
    /// - runs of blank lines collapse to one blank line (3+ consecutive
    ///   newlines become 2)
    /// - leading and trailing blank lines are removed.
    public static func normalizeWhitespace(_ text: String) -> String {
        let unified = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        let lines = unified.components(separatedBy: "\n").map { line -> String in
            var collapsed = ""
            collapsed.reserveCapacity(line.count)
            var inRun = false
            for character in line {
                if character == " " || character == "\t" {
                    if !inRun {
                        collapsed.append(" ")
                    }
                    inRun = true
                } else {
                    collapsed.append(character)
                    inRun = false
                }
            }
            while collapsed.hasSuffix(" ") {
                collapsed.removeLast()
            }
            return collapsed
        }
        // One pass over the lines: at most one blank line between content,
        // none at the edges.
        var normalized: [String] = []
        var pendingBlank = false
        for line in lines {
            if line.isEmpty {
                pendingBlank = !normalized.isEmpty
            } else {
                if pendingBlank {
                    normalized.append("")
                }
                normalized.append(line)
                pendingBlank = false
            }
        }
        return normalized.joined(separator: "\n")
    }

    // MARK: - Join

    /// The standard separators offered by "Join Selected". Raw values double
    /// as the DEBUG automation names.
    public enum JoinSeparator: String, CaseIterable, Sendable {
        case newline = "newline"
        case blankLine = "blank-line"
        case space = "space"
        case commaSpace = "comma-space"

        /// The literal separator inserted between clips.
        public var value: String {
            switch self {
            case .newline:
                return "\n"
            case .blankLine:
                return "\n\n"
            case .space:
                return " "
            case .commaSpace:
                return ", "
            }
        }

        /// Menu title.
        public var displayName: String {
            switch self {
            case .newline:
                return "Line Break"
            case .blankLine:
                return "Blank Line"
            case .space:
                return "Space"
            case .commaSpace:
                return "Comma and Space"
            }
        }
    }

    /// Joins clip contents with the chosen separator. Contents are joined
    /// exactly as stored — no trimming, so the caller can compose with
    /// `normalizeWhitespace` when wanted.
    public static func join(_ contents: [String], separator: JoinSeparator) -> String {
        contents.joined(separator: separator.value)
    }
}
