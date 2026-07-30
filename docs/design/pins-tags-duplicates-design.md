# Pins, Tags, Collections, Snippets, Duplicates — Implementation Design

Status: approved by lead 2026-07-30. Implements contracts 2/5/6 (feature
matrix rows 3, 4, 8). Sequenced strictly AFTER the Slice 3 merge (same-file
work in ClipboardPanelController). `contentHash` = `"sha256:<hex>"` is the
annotation key.

## Annotations store (Core, new ClipboardAnnotations.swift)

Path `<archiveRoot>/annotations/annotations.json`, 0700 dir / 0600 file,
atomic temp+replaceItemAt writes, symlink-rejecting load (settings-store
pattern). Schema:

```json
{ "annotationsVersion": 1, "updatedAt": "...",
  "annotations": { "sha256:...": { "pinned": true, "pinnedAt": "...",
      "tags": ["a"], "snippet": true, "snippetTitle": "...",
      "sensitivityOverride": null, "expiresAt": null } },
  "collections": [ { "id": "col_<UUID>", "name": "...", "createdAt": "...",
      "contentHashes": ["sha256:...", "..."] } ] }
```

- Every field decodeIfPresent+default; version missing → 1. Hand-written
  init(from:). `sensitivityOverride`/`expiresAt` are Slice 5 placeholders:
  round-tripped, never acted on in Slice 4.
- Invariants: snippet ⇒ pinned (setSnippet(true) pins; unpin clears snippet
  with a UI warning). Tags normalized (trim, drop empty, case-preserving,
  case-insensitive dedupe). Default-record GC on save when unreferenced.
- No file created until first mutation (no forced organization).
- Corrupt file: reads → empty doc; FIRST mutation renames it aside to
  `annotations.json.corrupt-<ISO8601>` then writes fresh. Reads never mutate.
- `annotationsVersion > 1` → READ-ONLY mode: known fields still load (pins
  still protect), every mutation throws `newerFormat`; file byte-identical.
  UI: "Saved by a newer version of Clipboard Archive."
- Cache: ledger-cache pattern (`@unchecked Sendable`, size+mtime signature
  stat per read). GUI = single writer; CLI read-only.
- API: load / annotation(for:) / pinnedContentHashes() / snippets() /
  allTags(); setPinned / setTags / setSnippet / collection CRUD +
  setMembership + moveItem / removeContentReference(contentHash:) (drops
  record + strips from all collections; called only when the last live
  occurrence is gone).

## Retention integration (ClipboardArchivePruner)

DECISION — pinned items sit OUTSIDE the retention limit: keep newest
`limit` UNPINNED events plus ALL pinned. (Counting pins inside the limit
would redact every new capture once pins ≥ limit — silent capture
breakage.) Document in pruner doc comment + Settings copy.

- `LiveEventReference` gains `contentHash`, populated in the decode loop —
  single choke point for both prune paths.
- `enforceRetentionLimit`: partition live by pinnedContentHashes(); guard +
  overflow selection on unpinned only; pinned-only-over-limit = early
  return, zero writes. Result gains `exemptPinnedEvents` +
  `keptCountedEvents` computed.
- `pruneContent` core gains `exemptContentHashes:`; public wrappers gain
  `includePinned: Bool = false` (the contract-5 explicit override);
  `ClipboardPruneResult` gains `exemptedPinnedEvents` (dry-run truthful).
- After pruning, for each pruned hash with an annotation and NO surviving
  live occurrence → removeContentReference (skip on dryRun).
- CLI prune gains `--include-pinned`; prints exempt counts.
- main.swift estimate semantics change: estimate = counted (unpinned)
  events; set from `result.keptCountedEvents`. Pin change → estimate stays
  (safe overestimate); UNPIN could undercount → panel's new
  `annotationsDidChange` closure sets estimate = nil (one reseed) + marks
  quick-picker cache dirty.

## Deletion integration (ClipboardArchiveRedactor)

Inside `redact(eventID:)` after ledger+index delete: capture contentHash
pre-tombstone; count remaining live occurrences via new
`ClipboardDerivedIndex.occurrenceIDs(contentHash:)` (stdin -json SQL on the
content_hash index) post-filtered through ClipboardSuppression (stale index
must not keep an annotation alive); index-file-absent fallback = one reader
scan. Zero left → removeContentReference (silently skipped in read-only
newer-format mode — dangling reference is harmless because all consumers
resolve through live occurrences). `ClipboardRedactionResult` gains
`removedAnnotationContentHash: String?`.

Delete confirms (panel + menu): if selection covers the LAST live
occurrence of a pinned/snippet hash, append warning ("Deleting its last
copy also removes its pin, tags, and snippet.") and retitle the confirm
button. Single explicit deletes need no second confirmation; the
separately-confirmed override is for Slice 5 bulk only.

## Duplicate grouping (History window)

- This Window: in-memory; existing predicate (type filter + query) FIRST,
  then group survivors by contentHash.
- All History: new `metaRows(filters:limit: cap 5000)` meta-only query →
  suppression filter → Swift grouping. NO SQL GROUP BY (ledger can't be
  consulted in SQL; counts must be honest under drift). Cap surfaced in the
  footer ("grouped over the most recent 5,000 clips"). Query-active mode
  groups structuredSearch results (add content_hash to its SELECT).
- Row model: `HistoryRow = single | group(GroupSummary) | occurrence(_,
  groupHash:)`; GroupSummary = hash, newest event, count, first/last dates.
  Keep NSTableView (no outline view). Group row: count capsule "×3" +
  chevron; metadata "3 copies · first Jul 12 · latest 2:14 PM". Expand via
  chevron / →|← keys / double-click; splices indented occurrence rows;
  state resets on reload/scope change.
- Copy: collapsed group copies the NEWEST occurrence via the shared no-
  re-capture path. Delete DISABLED on collapsed group rows (tooltip:
  expand to delete individual copies) — Slice 5 owns bulk.
- Toggle: "Group duplicates" checkbox below the type-filter row, both
  scopes, persisted as new settings key `historyGroupDuplicates` (default
  false, tolerant decode). Not in menu bar or Settings window.

## UI surfaces

- Pin: context menu (title reflects state, multi-select pluralized), detail
  header pin/pin.fill button, ⌘P via performKeyEquivalent (accessory app —
  no main menu), pin.fill row badge. One panel funnel `setPinned(_:for:)`
  catching newerFormat → status label.
- Tags: NSTokenField in detail pane (single selection only), completions
  from allTags(), commit on end-editing. No tag-browse UI this slice.
- Collections: NSPopUpButton above search — All Clips | Pinned | Snippets |
  collections | New Collection…; client-side hash filtering in both scopes;
  collection order = contentHashes order with drag-reorder when that filter
  is active (cut-line: reorder UI may defer one slice, API ships); detail
  "Add to Collection" popup with checkmark toggles.
- Snippets in quick picker: top section only when query empty and snippets
  exist; rows show snippetTitle + text.badge.star; resolution AT COMMIT
  TIME = occurrenceIDs ordered captured_at DESC → suppression →
  event(withID:) → content(for:) → shared copy path; zero live occurrences
  → disabled row. Dependencies gains `loadSnippets`; cache invalidated with
  the picker cache + annotationsDidChange. Optional Snippets submenu in the
  menu bar.

## Tests + harness receipts

- AnnotationsStoreTests: round-trips incl. placeholders; absent-file no-op
  reads; corrupt-file aside-rename preserving bytes; future-version fixture
  (pins still protect, mutations throw, file byte-identical); 0600/symlink;
  GC; snippet⇒pinned; unpin clears snippet; tag normalization; collection
  CRUD/order/move; removeContentReference strips membership; cache
  invalidation on external touch.
- Retention: pin oldest 2 over limit → both survive + exemptPinnedEvents=2;
  all-pinned-over-limit → zero writes (day-file mtimes unchanged);
  includePinned=true prunes + removes references; dry-run parity.
- Redactor: redact 1 of 2 occurrences → annotation intact; last → gone +
  out of collections; stale-index variant treated as last occurrence.
- DuplicateGroupingTests: counts/first/last/representative; filter+query
  composition; ordering; drift-excluded counts; blocked excluded; cap.
- Harness: history-screen env `_GROUP_DUPLICATES`, `_COLLECTION_FILTER`,
  gestures pin-selected/unpin-selected/expand-group/copy-selected + result
  JSON. Receipts: pin→prune→survives (recent-10, seed 14, pin 2 oldest,
  enforcement runs, pins survive + PNG badges); duplicates ×3 grouped +
  expanded snapshots + group-copy no-re-capture; fresh root renders with
  zero annotations IO; future-version fixture renders read-only status.

## Implementation order

Core store + tests → pruner exemption → redactor cleanup → index
occurrenceIDs/metaRows (+content_hash in search SELECT) → settings key →
CLI flag → panel row model + pin/tags/collections UI → picker snippets +
main.swift wiring/harness → matrix update.

## Top risks

| Risk | Mitigation |
|---|---|
| Panel collision with Slice 3 | sequence after merge; grouping is presentation over both scopes |
| Estimate drift with pin semantics | keptCountedEvents + unpin→reseed; tests assert steady-state no-scan |
| Annotations data loss across writers/versions | single-writer, CLI read-only, newer-format read-only, corrupt-aside |
| Pin protects all occurrences (hash identity) may surprise | group row + badges make identity visible; document row 3 |
