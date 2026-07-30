import Foundation
@testable import ClipboardArchiveCore

/// Reusable synthetic fixture builders for schema versioning tests.
/// Every byte here is authored test data; nothing is sampled from a live
/// archive (expansion contract 10).
enum SyntheticFixtures {
    static let knownContentTypes: [ClipboardContentType] = [.text, .url, .code, .blocked]

    /// A current-schema-version event for the given content type.
    static func currentEvent(
        contentType: ClipboardContentType = .text,
        id: String = "clip_synthetic_current",
        capturedAt: Date = Date(timeIntervalSince1970: 1_800_000_000)
    ) -> StoredClipboardEvent {
        let body = "synthetic fixture body for \(contentType.rawValue)"
        return StoredClipboardEvent(
            id: id,
            capturedAt: capturedAt,
            contentType: contentType,
            contentHash: "sha256:syntheticfixture",
            contentPreview: body,
            contentInline: body,
            rawContentPath: nil,
            sourceApp: ClipboardSourceApp(
                name: "Synthetic Fixture",
                bundleIdentifier: "local.synthetic.fixture"
            ),
            pasteboardTypes: ["public.utf8-plain-text"],
            byteCount: body.utf8.count,
            characterCount: body.count,
            lineCount: 1,
            privacyLabel: .privateLocal,
            allowedUse: [.localSearch, .localAnalysis],
            sensitivityFlags: [],
            uiVisibleUntil: capturedAt.addingTimeInterval(7 * 24 * 60 * 60)
        )
    }

    /// One current-version event per known content type.
    static func currentEventsPerContentType() -> [StoredClipboardEvent] {
        knownContentTypes.map { type in
            currentEvent(contentType: type, id: "clip_synthetic_current_\(type.rawValue)")
        }
    }

    /// A legacy version-1 NDJSON line exactly as builds before schema
    /// versioning wrote it: no `schemaVersion` key, sorted keys, ISO 8601
    /// dates, nil optionals omitted (Swift JSONEncoder behavior).
    static func legacyV1Line() -> String {
        #"{"allowedUse":["local-search","local-analysis"],"byteCount":29,"capturedAt":"2027-01-15T08:00:00Z","characterCount":29,"contentHash":"sha256:legacyfixture","contentInline":"synthetic legacy fixture note","contentPreview":"synthetic legacy fixture note","contentType":"text","id":"clip_20270115T080000Z_legacyfixtur_ab12cd34","lineCount":1,"pasteboardTypes":["public.utf8-plain-text"],"privacyLabel":"private-local","sensitivityFlags":[],"sourceApp":{"bundleIdentifier":"com.apple.Notes","name":"Notes"},"uiVisibleUntil":"2027-01-22T08:00:00Z"}"#
    }

    /// A line as a hypothetical future build might write it: higher
    /// `schemaVersion`, an unknown `contentType` raw value ("image"), and an
    /// extra unknown top-level field. Current code must decode it tolerantly.
    static func futureVersionLine() -> String {
        #"{"allowedUse":["local-search"],"byteCount":12,"capturedAt":"2027-01-15T09:00:00Z","characterCount":12,"contentHash":"sha256:futurefixture","contentImageMetadata":{"pixelHeight":480,"pixelWidth":640},"contentInline":"future-inline","contentPreview":"future-inline","contentType":"image","id":"clip_20270115T090000Z_futurefixtur_cd34ef56","lineCount":1,"pasteboardTypes":["public.png"],"privacyLabel":"private-local","schemaVersion":2,"sensitivityFlags":[],"sourceApp":{"bundleIdentifier":"com.apple.Preview","name":"Preview"},"uiVisibleUntil":"2027-01-22T09:00:00Z"}"#
    }

    /// A structurally broken line that must fail decoding and be skipped by
    /// reader-style decode loops.
    static func corruptLine() -> String {
        #"{"id":"clip_synthetic_corrupt","capturedAt":"not-a-date","contentType":"#
    }

    /// A blocked-event audit line as `ClipboardArchiveWriter` writes it.
    /// It is not a `StoredClipboardEvent`, so stored-event decode loops skip it.
    static func blockedEventLine() -> String {
        #"{"capturedAt":"2027-01-15T10:00:00Z","contentStored":false,"eventType":"blocked_sensitive_clipboard_item","reason":"source_app_denylist:dashlane","sourceApp":{"name":"Dashlane"}}"#
    }

    /// A line matching EXACTLY what the python generator inside
    /// scripts/scale-benchmark.sh emits (json.dumps with sort_keys=True and
    /// compact separators; explicit `"rawContentPath":null`). If the script's
    /// event shape changes, this builder and the script must change in the
    /// same commit (expansion contract 1).
    static func benchmarkGeneratorLine(index: Int = 42) -> String {
        let base = Date(timeIntervalSince1970: 1_767_225_600) // 2026-01-01T00:00:00Z
        let captured = base.addingTimeInterval(TimeInterval(index))
        let visible = captured.addingTimeInterval(7 * 24 * 60 * 60)
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        let body = "synthetic clipboard benchmark item \(index) benchmark-search-token-\(index % 997)"
        return #"{"allowedUse":["local-search","local-analysis"],"byteCount":\#(body.utf8.count),"capturedAt":"\#(formatter.string(from: captured))","characterCount":\#(body.count),"contentHash":"sha256:synthetic\#(index)","contentInline":"\#(body)","contentPreview":"\#(body)","contentType":"text","id":"clip_synthetic_\#(index)","lineCount":1,"pasteboardTypes":["public.utf8-plain-text"],"privacyLabel":"private-local","rawContentPath":null,"sensitivityFlags":[],"sourceApp":{"bundleIdentifier":"local.synthetic","name":"Synthetic"},"uiVisibleUntil":"\#(formatter.string(from: visible))"}"#
    }
}
