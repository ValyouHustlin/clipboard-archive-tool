# Expansion Cross-Cutting Contracts

Status: binding for the 2026-07 feature expansion. Established 2026-07-30
against HEAD `43ab766`. Every slice implementation must conform to these
contracts; changes to a contract require a lead decision recorded here.

## 1. Archive event schema versioning

- `StoredClipboardEvent` gains `schemaVersion: Int`. Missing key decodes as
  `1` (every existing archive line is version 1 by definition).
- The synthesized `Codable` conformance is replaced with a hand-written
  tolerant `init(from:)` following the existing `ClipboardSettings` pattern:
  every field added after version 1 uses `decodeIfPresent` with a safe
  default. No new required fields, ever, within the NDJSON format.
- Fields are never removed or renamed. Semantic changes bump
  `currentEventSchemaVersion` (a constant in `ClipboardModels.swift`).
- `ClipboardContentType` decoding becomes tolerant: unknown raw values decode
  as a new `.other(String)`-equivalent fallback (`unknown` case retaining the
  raw string in `pasteboardTypes`/metadata) instead of failing the whole
  line. Older app versions reading newer archives skip unknown lines exactly
  as they do today (decode-failure skip); that remains the documented
  forward-compat behavior.
- An `archive-format.json` marker file is written at the archive root on
  first write by new code: `{ "archiveFormatVersion": 1, "minReader": 1 }`
  (matching the release manifest; bumped only when the on-disk layout
  actually changes). Absence means format 1. Nothing deletes or rewrites
  existing v1 lines.
- `scripts/scale-benchmark.sh` embeds a second copy of the event shape; any
  schema change must update it in the same commit (checked by a test fixture
  that decodes a benchmark-generated line).

## 2. Item identity

- `id` = **occurrence identity**. Used for deletion, redaction, ledger,
  index rows, selection. Unchanged.
- `contentHash` (`sha256:<hex>`) = **content identity**. Used for duplicate
  grouping, pins, tags, and snippet references so annotations survive
  re-copies of the same content.
- The derived index `clipboard_meta` table gains a `content_hash` column and
  an index on it plus one on `captured_at` (see contract 3).
- The panel copy-back re-capture defect (panel does not update
  `lastContentHash`/`lastChangeCount`) is fixed in Slice 1 groundwork; all
  copy-back paths route through one shared "copy without re-capture" helper.

## 3. Derived index evolution

- The SQLite database gains `PRAGMA user_version = N`. On open, a version
  mismatch triggers a full rebuild into the new schema (existing atomic
  temp-db + `quick_check` + replace flow). The index remains disposable
  derived data; rebuild is always the recovery path.
- `ClipboardDerivedIndex.search` gains a structured result type (id,
  capturedAt, sourceApp, contentType, snippet) parsed from a
  machine-readable sqlite3 output mode; the raw-text CLI output is preserved
  for `index-search`.
- Full-archive UI search (Slice 3) reads the FTS index only; it never scans
  NDJSON on the UI thread.
- All SQL continues to stream over stdin to `/usr/bin/sqlite3`; clipboard
  content never appears in process arguments. Quote-escaping stays
  centralized in `escape()`.

## 4. Settings migration

- `ClipboardSettings` keeps the tolerant `decodeIfPresent` pattern and gains
  `settingsVersion: Int` (missing = 1) for future semantic migrations.
- Every new feature adds new keys with conservative defaults: new
  capabilities default to **off** or to current behavior. A settings file
  from any older build must load without behavior change beyond documented
  defaults.
- The settings file remains single-JSON, atomic-write, 0600, symlink-
  rejecting. New sub-structures (privacy rules, shortcuts) live inside
  `settings.json`, not new files.

## 5. Pins, tags, collections, snippets persistence

- User annotations live in a **sidecar annotations store**, NOT in the
  NDJSON archive: `<archiveRoot>/annotations/annotations.json` (versioned,
  atomic-write, 0600, same containment rules). The archive stays
  append-oriented; pin/tag toggles never rewrite day files.
- Annotation record keys on `contentHash`; holds: pinned flag + pinnedAt,
  tags `[String]`, collection ids, manual sensitivity override, snippet flag
  + optional snippet title, expiry date for expiring sensitive clips.
- Deletion contract: redacting/pruning all occurrences of a contentHash
  removes its annotation content reference; pinned content is **exempt from
  retention pruning and bulk cleanup by default** (explicit "include pinned"
  override required, separately confirmed).
- Collections are named ordered lists of contentHashes stored in the same
  file. Snippets are pinned annotations with `snippet: true`; snippet body
  resolves through the newest live occurrence.

## 6. Deletion, undo, and suppression semantics

- Tombstone redaction remains the single canonical destructive operation
  (rewrite line, delete body file, ledger append, index delete). Bulk
  operations compose it; nothing invents a second deletion path.
- Deletion is not undoable once executed (content is gone). Therefore every
  bulk operation must show a **truthful dry-run preview first** (event count
  + reclaimed bytes computed by the same code that will execute), and the
  confirmation names the irreversibility. "Undo" in UI copy is never used
  for redaction; tombstone-safety is the guarantee.
- Suppression check unification: a single `ClipboardSuppression` helper
  (ledger ids + `privacyLabel == .doNotIndex`) becomes the ONE gate used by
  reader, searcher, index rebuild, pruner, and every new read path. No third
  suppression mechanism may be added.
- `PrivacyLabel.restricted` currently has no reader semantics and is outside
  the suppression gate. Any slice that starts assigning it (manual
  sensitivity, Slice 5) MUST simultaneously define and test its read/index
  behavior — never tag events `.restricted` and assume they hide.
- The deletion ledger stays append-only; bulk operations write one ledger
  record per event with a machine-readable `reason` (`bulk-<criterion>`).

## 7. Rich content containment

- Rich bodies (images, files metadata, RTF, colors) store as body files
  under the existing `raw/YYYY/MM/YYYY-MM-DD_large-items/` layout with
  type-derived extensions (`.png`, `.rtf`, `.json`); `rawContentPath` stays
  a relative, containment-checked path. No new directory escape surface.
- File-type clips store **metadata only** (paths, names, sizes) by default —
  never file contents. Image clips store the image data; a configurable
  size cap (default 10 MiB) blocks larger payloads with a visible
  blocked-event reason.
- All rich reads/writes go through `ClipboardArchivePath.containedURL` and
  `ClipboardPrivateFileSystem` (0700/0600) like text bodies. Privacy filter
  runs before any rich write; concealed/transient types block rich content
  identically to text.

## 8. Global shortcut ownership

- The menu bar app is the sole owner of global shortcuts, registered via
  Carbon `RegisterEventHotKey` (no Accessibility permission required).
  Defaults: quick picker on ⌥⌘V, disabled until enabled in Settings.
- Shortcut configuration persists in `settings.json` (key code + modifiers +
  enabled flag per action). Conflicting registration failures surface in
  Settings, never silently.
- The quick picker is a nonactivating floating `NSPanel`. Copy-back works
  with zero permissions. Direct paste is a separate opt-in that requires
  Accessibility; the UI states the permission and degrades to copy-back
  when unauthorized. No CGEvent tap for capture — polling stays.

## 9. Performance contract (prerequisite fixes)

- Retention prune must stop doing a full archive rewrite + full FTS rebuild
  per capture in recent-10/50 modes. Slice 1 replaces it with a counted
  incremental prune (only when over limit, only rewriting affected day
  files, index deletes instead of full rebuild).
- Deletion-ledger reads get an mtime-keyed in-memory cache; menu rebuilds
  stop re-scanning the full archive when nothing changed.
- Quick picker must render from warm data in <100 ms at 50k-event scale;
  scale benchmark gates Slice 2.

## 10. Verification & privacy invariants (every slice)

- Never read, print, grep, sample, or copy live archive data. All tests and
  runtime observations use synthetic fixtures under `/tmp` isolated roots
  (`CLIPBOARD_ARCHIVE_ARCHIVE_ROOT`, `_INDEX_PATH`,
  `_APPLICATION_SUPPORT_ROOT`).
- Every migration ships old→new and failure-preserving fixtures. Every
  destructive feature ships dry-run/count evidence plus synthetic
  delete/verify tests. Every privacy rule ships allowed, blocked,
  false-positive, and non-retention fixtures.
- `check-local-only.sh` must keep passing; no networking of any kind enters
  app runtime. Encryption (Slice 8) uses CryptoKit AES-GCM with an HKDF/
  scrypt-class KDF from the platform — never hand-rolled primitives.
- The live installed app (PID 10609 at lane start) is never stopped,
  replaced, or pointed at by development instances.
