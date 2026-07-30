import Foundation
import Testing
@testable import ClipboardArchiveCore

@Suite("Clip Transformations")
struct ClipTransformationsTests {
    // MARK: - plainText

    @Test
    func testPlainTextFixtureTable() {
        let fixtures: [(input: String, expected: String, note: String)] = [
            ("hello world", "hello world", "ordinary text is untouched"),
            ("a\r\nb\rc", "a\nb\nc", "CRLF and CR become LF"),
            ("a\u{2028}b\u{2029}c", "a\nb\nc", "line/paragraph separators become LF"),
            ("pre\u{FFFC}post", "prepost", "attachment placeholders dropped"),
            ("", "", "empty stays empty"),
            ("🙂 emoji und ümlaut", "🙂 emoji und ümlaut", "unicode preserved")
        ]
        for fixture in fixtures {
            #expect(
                ClipTransformations.plainText(from: fixture.input) == fixture.expected,
                "\(fixture.note)"
            )
        }
    }

    // MARK: - stripFormatting

    @Test
    func testStripFormattingFixtureTable() {
        let fixtures: [(input: String, expected: String, note: String)] = [
            ("\u{201C}Hello\u{201D} \u{2018}world\u{2019}", "\"Hello\" 'world'", "smart quotes"),
            ("\u{00AB}guillemets\u{00BB}", "\"guillemets\"", "guillemets become double quotes"),
            ("en \u{2013} em \u{2014} minus \u{2212}", "en - em - minus -", "dashes to hyphen"),
            ("wait\u{2026}", "wait...", "ellipsis to three dots"),
            ("zero\u{200B}width\u{FEFF}gone\u{2060}", "zerowidthgone", "zero-width stripped"),
            ("soft\u{00AD}hyphen", "softhyphen", "soft hyphen stripped"),
            ("\u{202E}reversed\u{202C}", "reversed", "directional overrides stripped"),
            ("\u{200E}mark\u{200F}", "mark", "LRM/RLM stripped"),
            ("\u{2066}isolate\u{2069}", "isolate", "directional isolates stripped"),
            ("می\u{200C}خواهم", "میخواهم", "ZWNJ stripped, RTL letters preserved"),
            ("مرحبا بالعالم", "مرحبا بالعالم", "plain RTL text untouched"),
            ("a\u{200D}b", "ab", "text ZWJ stripped"),
            ("👨\u{200D}👩\u{200D}👧", "👨\u{200D}👩\u{200D}👧", "emoji family ZWJ preserved"),
            ("❤\u{FE0F}\u{200D}🔥", "❤\u{FE0F}\u{200D}🔥", "variation-selector emoji ZWJ preserved"),
            ("plain ascii -- unchanged", "plain ascii -- unchanged", "ascii untouched"),
            ("", "", "empty stays empty")
        ]
        for fixture in fixtures {
            #expect(
                ClipTransformations.stripFormatting(fixture.input) == fixture.expected,
                "\(fixture.note)"
            )
        }
    }

    @Test
    func testStripFormattingIsTotalOnHugeInput() {
        let huge = String(repeating: "\u{201C}x\u{201D}\u{200B} – y\u{2026}\n", count: 20_000)
        let stripped = ClipTransformations.stripFormatting(huge)
        #expect(!stripped.contains("\u{200B}"))
        #expect(!stripped.contains("\u{2026}"))
    }

    // MARK: - cleanURL

    @Test
    func testCleanURLFixtureTable() {
        let fixtures: [(input: String, expected: String, note: String)] = [
            (
                "https://example.com/a?utm_source=x&id=42&fbclid=zz#frag",
                "https://example.com/a?id=42#frag",
                "mixed tracking and real params, fragment preserved"
            ),
            (
                "https://example.com/a?gclid=1#top",
                "https://example.com/a#top",
                "question mark dropped when the query empties, fragment kept"
            ),
            (
                "https://example.com/a?utm_source=1&utm_medium=2&utm_campaign=3",
                "https://example.com/a",
                "all-tracking query removed entirely"
            ),
            (
                "https://example.com/search?q=hello%20world&utm_medium=email",
                "https://example.com/search?q=hello%20world",
                "percent-encoding of survivors preserved byte-for-byte"
            ),
            (
                "https://example.com/p?b=2&a=1&utm_x=3&si=s",
                "https://example.com/p?b=2&a=1",
                "surviving param order preserved; utm_ prefix matches any suffix"
            ),
            (
                "before https://example.com/x?fbclid=1 middle https://example.com/y?gbraid=2&keep=1 after",
                "before https://example.com/x middle https://example.com/y?keep=1 after",
                "multiple URLs in one text"
            ),
            (
                "(see https://example.com/a?fbclid=1).",
                "(see https://example.com/a).",
                "trailing sentence punctuation never treated as query bytes"
            ),
            (
                "Tom & Jerry, si=fun & utm_source",
                "Tom & Jerry, si=fun & utm_source",
                "non-URL ampersand text untouched"
            ),
            (
                "https://example.com/plain/path",
                "https://example.com/plain/path",
                "URL without query untouched"
            ),
            (
                "https://example.com/a?keep=1&also=2",
                "https://example.com/a?keep=1&also=2",
                "URL with no tracking params returned byte-for-byte"
            ),
            (
                "https://example.com/a?music=1&si=abc",
                "https://example.com/a?music=1",
                "exact-name matching: si removed"
            ),
            (
                "https://example.com/a?psi=1&visit=2",
                "https://example.com/a?psi=1&visit=2",
                "psi/visit do not match si"
            ),
            (
                "https://example.com/a?UTM_SOURCE=x&Keep=1",
                "https://example.com/a?Keep=1",
                "tracking names match case-insensitively, survivors keep case"
            ),
            (
                "https://example.com/a?a=1&&b=2&fbclid=9",
                "https://example.com/a?a=1&&b=2",
                "empty query pieces survive byte-for-byte"
            ),
            (
                "https://example.com/a#frag?utm_source=1",
                "https://example.com/a#frag?utm_source=1",
                "question mark inside the fragment is never parsed as a query"
            ),
            (
                "https://example.com/a?q=what%3F&msclkid=1",
                "https://example.com/a?q=what%3F",
                "encoded question mark in a value survives"
            ),
            (
                "no urls here at all? just a question & an ampersand",
                "no urls here at all? just a question & an ampersand",
                "prose with ? and & untouched"
            ),
            (
                "://?utm_source=1",
                "://?utm_source=1",
                "scheme-less URL-shaped junk untouched"
            ),
            ("", "", "empty stays empty")
        ]
        for fixture in fixtures {
            #expect(
                ClipTransformations.cleanURL(fixture.input) == fixture.expected,
                "\(fixture.note)"
            )
        }
    }

    @Test
    func testCleanURLHandlesManyURLsInHugeText() {
        let line = "x https://example.com/r?utm_source=a&keep=1 y\n"
        let huge = String(repeating: line, count: 5_000)
        let cleaned = ClipTransformations.cleanURL(huge)
        #expect(!cleaned.contains("utm_source"))
        #expect(cleaned.contains("https://example.com/r?keep=1"))
    }

    @Test
    func testCleanURLIsIdempotent() {
        let input = "https://example.com/a?utm_source=x&id=42&fbclid=zz#frag and https://example.com/b?si=1"
        let once = ClipTransformations.cleanURL(input)
        #expect(ClipTransformations.cleanURL(once) == once)
    }

    // MARK: - normalizeWhitespace

    @Test
    func testNormalizeWhitespaceFixtureTable() {
        let fixtures: [(input: String, expected: String, note: String)] = [
            ("a  \t b", "a b", "space/tab runs collapse to one space"),
            ("line   \nnext", "line\nnext", "line-trailing whitespace trimmed"),
            ("a\n\n\n\nb", "a\n\nb", "3+ newlines collapse to 2"),
            ("a\n\nb", "a\n\nb", "a single blank line is preserved"),
            ("a\nb", "a\nb", "single newline preserved"),
            ("\n\nx\n\n", "x", "leading/trailing blank lines removed"),
            ("  \t \n\t\n", "", "whitespace-only input empties"),
            ("a\r\n\r\n\r\nb", "a\n\nb", "CRLF blank runs collapse"),
            ("a \n \nb", "a\n\nb", "whitespace-only lines count as blank"),
            ("tab\tstop", "tab stop", "single tab becomes one space"),
            ("", "", "empty stays empty")
        ]
        for fixture in fixtures {
            #expect(
                ClipTransformations.normalizeWhitespace(fixture.input) == fixture.expected,
                "\(fixture.note)"
            )
        }
    }

    @Test
    func testNormalizeWhitespaceIsIdempotent() {
        let fixtures = [
            "a  \t b\n\n\n\nc   \n",
            "  leading run",
            "\n\n\nx\t\ty\n \n \nz  \n\n",
            "unicode 🙂  \u{00A0} kept\n\n\n",
            ""
        ]
        for fixture in fixtures {
            let once = ClipTransformations.normalizeWhitespace(fixture)
            let twice = ClipTransformations.normalizeWhitespace(once)
            #expect(twice == once, "normalizeWhitespace must be idempotent for \(fixture.debugDescription)")
        }
    }

    @Test
    func testNormalizeWhitespaceLeavesNonBreakingSpaceAlone() {
        // Spec is literal: spaces and tabs only. NBSP is content.
        #expect(ClipTransformations.normalizeWhitespace("a\u{00A0}b") == "a\u{00A0}b")
    }

    // MARK: - join

    @Test
    func testJoinSeparators() {
        let contents = ["one", "two", "three"]
        #expect(ClipTransformations.join(contents, separator: .newline) == "one\ntwo\nthree")
        #expect(ClipTransformations.join(contents, separator: .blankLine) == "one\n\ntwo\n\nthree")
        #expect(ClipTransformations.join(contents, separator: .space) == "one two three")
        #expect(ClipTransformations.join(contents, separator: .commaSpace) == "one, two, three")
    }

    @Test
    func testJoinEdgeCases() {
        #expect(ClipTransformations.join([], separator: .newline) == "")
        #expect(ClipTransformations.join(["solo"], separator: .commaSpace) == "solo")
        #expect(
            ClipTransformations.join(["a\nmultiline", "b"], separator: .blankLine)
                == "a\nmultiline\n\nb"
        )
    }

    @Test
    func testJoinSeparatorAutomationNamesRoundTrip() {
        for separator in ClipTransformations.JoinSeparator.allCases {
            #expect(ClipTransformations.JoinSeparator(rawValue: separator.rawValue) == separator)
        }
    }
}
