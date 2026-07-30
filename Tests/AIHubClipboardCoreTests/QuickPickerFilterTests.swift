import Foundation
import Testing
@testable import ClipboardArchiveCore

@Suite("Quick Picker Filter")
struct QuickPickerFilterTests {
    private func fixtureEvents() -> [StoredClipboardEvent] {
        var launchNote = SyntheticFixtures.currentEvent(
            contentType: .text,
            id: "clip_synthetic_note"
        )
        launchNote.contentPreview = "Review the Launch checklist for the clipboard rollout"
        launchNote.sourceApp = ClipboardSourceApp(
            name: "Notes",
            bundleIdentifier: "com.apple.Notes"
        )

        var link = SyntheticFixtures.currentEvent(
            contentType: .url,
            id: "clip_synthetic_link"
        )
        link.contentPreview = "https" + "://example.test/design/history"
        link.sourceApp = ClipboardSourceApp(
            name: "Safari",
            bundleIdentifier: "com.apple.Safari"
        )

        var snippet = SyntheticFixtures.currentEvent(
            contentType: .code,
            id: "clip_synthetic_code"
        )
        snippet.contentPreview = "struct ClipRow { let title: String }"
        snippet.sourceApp = ClipboardSourceApp(
            name: "Xcode",
            bundleIdentifier: "com.apple.dt.Xcode"
        )

        return [launchNote, link, snippet]
    }

    @Test
    func testEmptyAndWhitespaceQueriesReturnAllEvents() {
        let events = fixtureEvents()
        #expect(ClipboardQuickPickerFilter.filter(events: events, query: "") == events)
        #expect(ClipboardQuickPickerFilter.filter(events: events, query: "   ") == events)
        #expect(ClipboardQuickPickerFilter.filter(events: events, query: "\n\t") == events)
    }

    @Test
    func testMatchesPreviewCaseInsensitively() {
        let events = fixtureEvents()
        let matches = ClipboardQuickPickerFilter.filter(events: events, query: "LAUNCH")
        #expect(matches.map(\.id) == ["clip_synthetic_note"])
    }

    @Test
    func testMatchesSourceAppName() {
        let events = fixtureEvents()
        let matches = ClipboardQuickPickerFilter.filter(events: events, query: "safari")
        #expect(matches.map(\.id) == ["clip_synthetic_link"])
    }

    @Test
    func testMatchesContentTypeRawValue() {
        let events = fixtureEvents()
        let matches = ClipboardQuickPickerFilter.filter(events: events, query: "code")
        #expect(matches.map(\.id) == ["clip_synthetic_code"])
    }

    @Test
    func testQueryIsTrimmedBeforeMatching() {
        let events = fixtureEvents()
        let matches = ClipboardQuickPickerFilter.filter(events: events, query: "  xcode \n")
        #expect(matches.map(\.id) == ["clip_synthetic_code"])
    }

    @Test
    func testNoMatchReturnsEmptyAndPreservesOrderOtherwise() {
        let events = fixtureEvents()
        #expect(ClipboardQuickPickerFilter.filter(events: events, query: "zzz-nomatch").isEmpty)

        // Multiple matches keep the input (recency) order.
        let appleMatches = ClipboardQuickPickerFilter.filter(events: events, query: "clip")
        #expect(appleMatches.map(\.id) == ["clip_synthetic_note", "clip_synthetic_code"])
    }

    @Test
    func testUnknownContentTypeRawValueIsSearchable() {
        var event = SyntheticFixtures.currentEvent(
            contentType: .other("image"),
            id: "clip_synthetic_image"
        )
        event.contentPreview = "screenshot metadata"
        let matches = ClipboardQuickPickerFilter.filter(events: [event], query: "image")
        #expect(matches.map(\.id) == ["clip_synthetic_image"])
    }
}
