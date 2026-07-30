# Rich Clipboard Formats — Implementation Design

Status: approved by lead 2026-07-30. Implements contracts 1/7/10 (feature
matrix row 6). Verified baseline facts: `.other` lines RENDER under current
builds (never skipped); `content(for:)` falls back to `contentPreview`; the
panel/picker icon funcs handle `.other`; index `content_type` is plain TEXT
(no schema bump needed for new kinds).

## Content types + schema v2

New first-class cases: `.image` ("image"), `.fileReference`
("file-reference"), `.richText` ("rich-text"), `.color` ("color").
Formatted links stay `contentType: "url"` (a titled link IS a URL — keeps
Links filter/index/old-build icon working); `richContent.kind == "link"`
carries the title. Old builds decode new raw values as `.other(...)` and
render preview text; copy yields preview. That is the designed degradation.

`StoredClipboardEvent` gains ONE tolerant field `richContent:
ClipboardRichContent?`; `currentSchemaVersion = 2`.
`ClipboardRichContent { kind (tolerant raw string), bodyPath?,
bodyByteCount?, bodyType?, imagePixelWidth/Height?, files?
[{name,path,byteCount?,uti?}], fileCount?, filesTruncated?, colorHex?,
colorSpace?, linkURL?, linkTitle?, hasPlainTextFallback }`.

PER-LINE VERSION STAMPING (contract 1 amendment): writer stamps
`schemaVersion = richContent == nil ? 1 : 2` — text-only lines stay
byte-identical to today (benchmark drift fixture unchanged).
`rawContentPath` remains PLAIN-TEXT-ONLY forever; rich bytes live only in
`richContent.bodyPath` (this is what makes old-build fallback safe).
`archive-format.json` stays at 1 (layout unchanged).

File-list spill: >100 files → first 100 inline + filesTruncated + full
list in `<id>.json` body.

## Capture (pollPasteboard)

`ClipboardCapture.rich: ClipboardRichPayload?` (defaulted; call sites
unchanged): image(data,uti,w,h) | rtf(data) | fileList | color(hex,space) |
link(url,title). `capture.content` is ALWAYS the plain-text fallback
(empty for images) — the filter/secret-detector/FTS substrate.

Classification priority behind new `captureRichContent` setting (default
true): fileURL > png/tiff > rtf > color > public.url+url-name > plain
string (existing path untouched). changeCount guard unchanged (only cost
when idle). Image: check `data.count` vs cap BEFORE any decode/hash;
dimensions via CGImageSource header parse (no pixel decode). Dedup:
per-kind canonical `dedupHashValue` in Core (text unchanged; rich = hash
of canonical bytes) — used identically by capture and copy-back. CLI
monitor stays text-only this slice (reads v2 tolerantly).

## Storage per kind

| kind | hash source | body file | inline | preview |
|---|---|---|---|---|
| image | image bytes | always .png/.tiff in large-items | never | "Image 1920×1080 (2.1 MB)" |
| rtf | RTF bytes | always .rtf; plain fallback uses existing inline/txt rules | fallback only | fallback 240 chars |
| file-list | joined paths | .json only >100 files | descriptor inline | "3 files: a.pdf, b.png…" |
| color | hex | none | always | "Color #3A7BFF" |
| link | url+\n+title | none | always | "Title — url" |

10 MiB image cap (`richImageMaxBytes` setting) enforced in Ingestor AFTER
filter-allow, BEFORE any write → blocked event reason
`image_exceeds_size_cap:<n>b:limit:<cap>b`; menu status wording keyed off
reason prefix. Body writes: existing createDirectory → atomic write →
secureFile 0600 → relative path; write body BEFORE NDJSON append, delete
body on append failure (also fix the pre-existing text-body leak).

## Privacy

Concealed/transient types block rich via the EXISTING first check (types
list already flows through). Secret detector runs on the plain fallback:
rtf fallback, link url+\n+title, file-list joined paths, color hex; images
have empty content. DECISION: file NAMES go into FTS body; full paths stay
in event metadata only (search "invoice.pdf" works; directory structure
never enters snippets). doNotIndex/restricted interplay unchanged.

## Index

No schema change, no user_version bump. Ingestor gains indexBody(for:):
image→preview text; files→names joined; rtf→fallback; color→hex;
link→url+title; text unchanged. Rebuild derives body via content(for:)
which returns preview for images / fallback for rtf — matches upsert by
construction (pin with a parity test). Panel type filter → 6 segments
All|Text|Links|Code|Images|Files (.richText surfaces under All —
documented; equality filter can't OR).

## Rendering + copy-back

Detail per kind: image = CGImageSourceCreateThumbnailAtIndex max 1024 px
(NEVER full NSImage decode), NSCache ~32 MB keyed by event id, fetched
off-main generation-guarded; file-list = monospaced name·size·path with
"(missing)" annotations; rtf = NSAttributedString(rtf:) with plain
fallback on parse failure; color = swatch + hex + space; link = title +
URL. New Core APIs: `reader.richBody(for:)` (containment-checked) and
`ClipboardContentType.systemSymbolName` (photo / doc.on.doc / textformat /
paintpalette; delete the two duplicated private icon funcs).

Copy-back: new `copyEventToPasteboardWithoutRecapture(_ event:)` writing
ORIGINAL representations (image: stored bytes under own type + derived
second rep; rtf: .rtf + .string fallback; files: NSURL objects + paths
string; color: NSColor + hex; link: .URL + url-name + .string), then
dedup sync using the SAME dedupHashValue. Panel/picker copy closures
become event-based; multi-select join stays plain-text (joins fallbacks —
documented). Redactor/pruner also delete richContent.bodyPath and null it
in tombstones; health scans extend extensions to
[code,txt,png,tiff,rtf,json] and include rich bodies.

## Tests + harness

Fixtures: embedded 1×1 PNG (~70 B), tiny RTF, file-list/color/link
builders, pinned v2 lines; retarget futureVersionLine unknown type
"image"→"hologram" + new pinned test v2-image-decodes-as-.image.
RichContentTests: per-kind round-trip (bytes equality via richBody); text
BYTE-IDENTITY pre/post (pinned v1-shape string); 11 MiB cap-block (no body
file, no hash); `../../escape.png` containment throw + redactor
skippedUnsafeBodyPath; privacy fixtures per contract 10 (concealed image,
secret-bearing rtf fallback/link, allowed/false-positive);
index-per-kind + upsert==rebuild parity + NOT-found-by-path-token;
migration/degradation receipts (v1→nil; v2→.image; old-build-behavior
pin); rich redaction (body gone, tombstone richContent nil); dedup (copy
back + poll tick → no new event).
Harness: seeded rich fixtures → history/picker/detail PNGs per kind; new
`..._RICH_CAPTURE=image|files|rtf|color|link` mode writing
multi-representation items to the automation pasteboard + one poll tick +
result JSON {kindStored, counts, bodyFileExists, preview}; cap-block
variant; copy-back byte-equality receipt.

## Top risks

| Risk | Mitigation |
|---|---|
| Huge pasteboard image materialized by data(forType:) | size check before any decode/hash; prefer .png; transient peak documented |
| Old-build binary mojibake | forbidden by design: rawContentPath stays plain-text-only |
| Rich bodies orphaned by old-build redaction | forward-compat gap; health counts tombstoned-rich-bodies; log in matrix |
| Detail memory spike | cap + 1024 px thumbnail + bounded NSCache |
| sensitivityFlags in-memory-only mutation quirk | pre-existing; log in matrix, don't fix silently |

Implementation order: models → settings → writer → ingestor → reader →
redactor/pruner/health → main.swift poll+copy → panel → picker → settings
UI toggle → tests/harness → contract amendment + matrix row 6.
