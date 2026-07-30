# Full-Archive UI Search — Implementation Design

Status: approved by lead 2026-07-30. Implements contract 3 (feature matrix
row 2). RECONCILIATION NOTE: this design was drafted against the
pre-Slice-1 tree. Slice 1 has since landed: `ClipboardSuppression` EXISTS
(use it — do not create a second one), the shared no-re-capture copy path
EXISTS as `copyToPasteboardWithoutRecapture(_:)` on the app delegate (route
archive-result copies through it — do not create `ClipboardCopyService`),
and the ledger cache already makes `deletedIDs()` cheap. Everything else
below stands.

## Output mode decision: sqlite3 `-json` over stdin

Structured search uses `/usr/bin/sqlite3 -json -batch <db>` with SQL
streamed over stdin (never argv — user query text must not appear in
process arguments). Rationale: clipboard text can legally contain any
in-band delimiter (0x1F/0x1E/newlines), so separator tricks silently
mis-frame rows; JSON mode escapes all control characters and round-trips
any valid-UTF-8 string exactly. All indexed content entered as Swift String
(valid UTF-8) and there are no BLOB columns, so JSON-mode hazards don't
apply. Parser quirks: empty result set emits EMPTY STDOUT (treat as `[]`);
undecodable stdout → typed `malformedOutput` error. Pipe discipline: write
SQL + close stdin, read stdout to end, THEN waitUntilExit.

## Index schema v2 (one bump, one rebuild)

```swift
public static let currentIndexSchemaVersion = 2  // 0 = pre-versioning
```

```sql
PRAGMA user_version=2;
CREATE VIRTUAL TABLE IF NOT EXISTS clipboard_fts USING fts5(
  id UNINDEXED, captured_at UNINDEXED, source_app, content_type, preview, body);
CREATE TABLE IF NOT EXISTS clipboard_meta(
  id TEXT PRIMARY KEY, captured_at TEXT, source_app TEXT, bundle_id TEXT,
  content_type TEXT, byte_count INTEGER, raw_content_path TEXT,
  content_hash TEXT, preview TEXT);
CREATE INDEX IF NOT EXISTS clipboard_meta_captured_at_idx ON clipboard_meta(captured_at);
CREATE INDEX IF NOT EXISTS clipboard_meta_content_hash_idx ON clipboard_meta(content_hash);
```

- `content_hash` + its index serve Slice 4 duplicates; `preview` lets
  empty-query browsing avoid joining into FTS on an UNINDEXED column;
  `captured_at` is fixed-width ISO8601 UTC so lexicographic = chronological
  and range scans use the new index. Both INSERT sites (rebuild + upsert)
  gain the two new values.
- `ensureCurrentSchema()`: index missing → rebuild; `pragma_user_version`
  != 2 → rebuild. Called from structuredSearch/browse/distinctSourceApps/
  upsert OUTSIDE the exclusive lock (not reentrant; race = idempotent
  double rebuild). rebuild() stamps user_version inside the existing
  temp-db + quick_check + atomic-replace flow. `delete` stays
  version-agnostic.
- Mixed versions: old binary INSERTs name columns explicitly → new columns
  NULL, healed on next rebuild.

## Core API additions (ClipboardDerivedIndex)

- `ClipboardIndexSearchFilters { since?, until?, bundleID?, sourceAppName?, contentType? (String, tolerance-friendly) }`
- `ClipboardIndexSearchResult { id, capturedAt, sourceApp, bundleID?, contentType, snippet, byteCount }`
- `structuredSearch(_ query:, filters:, limit: 1...500)` — FTS MATCH JOIN
  clipboard_meta ON id (PK lookup per hit), `snippet(clipboard_fts, 5, '',
  '', ' … ', 24)`, `m.content_type <> 'blocked'` defense-in-depth, filters
  on meta columns, ORDER BY captured_at DESC.
- `browse(filters:, limit:)` — meta-only, uses `preview AS snip`.
- `distinctSourceApps()` for the app filter popup.
- FTS escaping for UI path: tokenize on whitespace, each token wrapped in
  escaped double quotes, joined (implicit AND) — immune to user-typed FTS
  operators. Legacy `search()`/`escapeFTS` untouched for the CLI.
- Suppression parity: structuredSearch/browse drop ids in
  `ClipboardSuppression` at read time — a rebuilt-from-stale-archive index
  plus later ledger appends cannot leak. (Post-filter may under-fill
  `limit`; acceptable; comment it.)

## Reader by-id fetch

`ClipboardArchiveReader.event(withID:)`:
1. Validate `clip_` prefix + 8 ASCII digits at offsets 5..<13 (UTC
   yyyyMMdd). Malformed → nil (NEVER a full archive scan).
2. Derive the one day file `raw/<yyyy>/<MM>/<yyyy-MM-dd>_clipboard-events.ndjson`
   (id and day file use the same UTC formatters — exact mapping), resolve
   via `ClipboardArchivePath.containedURL`.
3. Missing file → nil. Scan that file only, tolerant decode, match id.
4. Gate through `ClipboardSuppression` before returning (stale index must
   not resurrect deleted/doNotIndex content). Suppressed → nil.

## Panel UI (ClipboardPanelController)

Sidebar top-to-bottom: heading → NEW scope segmented control "This Window |
All History" → search field → existing type segments → all-history-only
filter row (date-range popup: Any Time/Today/7/30/90 days/This Year; app
popup from distinctSourceApps) → table → status footer.

State machine (all-history): `browse | searching | results([...]) | empty |
error(String) | preparingIndex`. 250 ms debounce via DispatchWorkItem +
generation counter (stale results dropped); queries on a serial background
queue; `preparingIndex` shows "Preparing search index…" while
ensureCurrentSchema rebuilds off-main. Row select → "Loading clip…" →
background `event(withID:)` + `content(for:)`; nil → "This clip is no
longer in the archive." + Rebuild Search Index button (also the .error
recovery). Scope back to This Window restores the existing in-memory path
UNCHANGED; pending work cancelled. Esc: clears query first, second Esc
returns to This Window.

Keyboard-first: search field `doCommandBy` moveDown → table row 0; table
subclass fires Return → copy via the shared no-re-capture path (works in
both scopes). All-history copy: fetched event → `content(for:)` →
`copyToPasteboardWithoutRecapture`.

## DEBUG harness additions (main.swift)

New env: `..._SCOPE` (working|all-history), `..._DATE_FILTER`,
`..._APP_FILTER`; reuse `_QUERY`/type filter. All-history flow: seed
fixtures; append one hand-built doNotIndex line; rebuild index; THEN
`recordDeletion` for one seeded event WITHOUT index delete (manufactures
stale-index + ledger drift); snapshot must not show either clip. New panel
DEBUG methods `performAutomationScope/DateFilter/AppFilter` +
`automationIsSettled` polled (0.1 s steps, 5 s cap) instead of fixed sleep.
Keep the /tmp isolation guard mandatory.

## Test plan (new ClipboardIndexSearchTests.swift, /tmp roots)

- Hostile-content round-trip: SQL-injection-shaped quotes, backslashes,
  newlines/tabs, unicode NFC/NFD + emoji, raw 0x1F/0x1E bytes, large-body
  event; assert exact field round-trip + snippet marker + separator bytes
  intact. Empty result → []; corrupt index → typed error.
- Filter correctness: inclusive date bounds (exactly-at included, ±1s
  excluded), bundle/app-name/type filters, combined, browse-mode filters,
  newest-first order, limit.
- user_version: hand-built legacy v0 index → structuredSearch triggers
  rebuild → user_version==2 + new columns exist; missing file → build;
  failed rebuild preserves prior index; second ensure is a no-op
  (mtime/inode compare).
- Suppression: ledger-only drift excluded from search/browse and
  event(withID:) nil; doNotIndex excluded everywhere; synthetic 'blocked'
  row (raw SQL) excluded by the SQL guard.
- By-id: round-trip incl. large body; malformed/traversal-shaped ids → nil
  without escaping root; absent day file → nil.
- Harness receipts: all-history query snapshot (drift + doNotIndex absent),
  filter snapshots, empty-state snapshot, working-window regression
  snapshot.

## Top risks

| Risk | Mitigation |
|---|---|
| First All-History entry triggers full rebuild at scale | one combined bump; preparingIndex state; off-main; menu rebuild unchanged |
| FTS syntax errors from user input | per-token quote escaping |
| Stale-index leak after ledger drift | read-time suppression in search/browse AND event(withID:); harness manufactures the drift |
| Copy from results re-captures | shared no-re-capture path only |
| Ledger scan per keystroke | debounce + Slice 1 ledger cache |

Implementation order: index schema+APIs+tests → reader by-id → panel scope
UI → harness → matrix update.
