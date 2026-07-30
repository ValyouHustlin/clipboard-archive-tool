# Clipboard Archive Architecture

Last verified against source: 2026-07-30 (0.2.0 expansion complete)

## Product Boundary

Clipboard Archive is a native Swift macOS menu bar app plus a local CLI. The
installed app captures text from `NSPasteboard`, filters it before storage, and
writes accepted events to a user-selected local archive. It has no app-runtime
network client, account, cloud sync, telemetry, or remote service.

GitHub is used only by separate, user-run install/update scripts.

## Runtime Components

```text
NSPasteboard
  -> menu bar polling loop
       -> ClipboardCaptureGate (private mode / pause decision, pure Core)
       -> rich classification (fileURL > image > RTF > color > titled link)
  -> ClipboardPrivacyFilter (type denylist, built-ins, per-app rules,
       legacy exclusions, SecretDetector)
       -> blocked-event metadata only
       -> accepted StoredClipboardEvent (schema-versioned, tolerant decode)
  -> append-oriented NDJSON archive
       -> inline text, or a same-day large-body / rich-body file
  -> incremental derived SQLite FTS upsert (schema v2, user_version)
  -> readers: menu, History window (This Window + All History scopes),
       quick picker, Storage & Health dashboard

Sidecar: annotations/annotations.json (pins, tags, collections, snippets,
manual sensitivity, expiry) keyed on content hash — never in the NDJSON.

CLI
  -> search / redact / prune / bulk / sweep-expired / health / manifest /
     index repair / backup create-inspect-restore
  -> the same core library and archive format
```

`ClipboardArchiveCore` owns the data model (versioned event schema with
tolerant decoding), filtering, the capture gate, archive reader/writer,
redaction, the promoted pruner core, the bulk engine
(`ClipboardBulkEngine`: one shared dry-run/execute path with truthful
reclaim accounting), the expiry sweeper, the annotations sidecar store,
duplicate grouping, clip transformations (`ClipTransformations`: pure
plain-text/strip/URL-cleanup/whitespace/join functions), encrypted backup
(`ClipboardBackup` + `ClipboardBackupImporter`: CLIPBAK1 AES-GCM containers
with PBKDF2-calibrated keys and a journaled, ledger-first import), health
reporting, settings, version info (`ClipboardVersionInfo`), the
launch-at-login state model (`ClipboardLoginItemState`), and the derived
index.

`ClipboardArchiveMenuBar` owns pasteboard polling, source-app attribution,
pause/private-mode/storage controls, the History window, the quick picker
panel and its Carbon global hotkey, the Storage & Health dashboard, the
bulk cleanup sheet, the backup UI, settings (including the SMAppService
login-item wrapper), and the single-instance file lock. All copy-back
surfaces route through one shared no-re-capture pasteboard helper.

The primary UI is a native AppKit split-view window. Its sidebar owns search,
recent event metadata, and clip count; its detail surface reads full content
only for the selected event and sizes the preview card from content metadata.
Search from the menu focuses this same window instead of creating a separate
modal result flow.

`clipboard-archive` exposes local maintenance and retrieval commands.

`clipboard-archive-checks` is a synthetic compatibility-check executable.
`Tests/AIHubClipboardCoreTests` is a Swift Testing suite covering the
load-bearing privacy, path-containment, settings-migration, health, manifest,
redaction, and derived-index behaviors.

## Default Paths

Portable installs use:

```text
~/Library/Application Support/ClipboardArchive/Archive/clipboard-history
~/Library/Application Support/ClipboardArchive/Indexes/clipboard-search.sqlite
~/Library/Application Support/ClipboardArchive/settings.json
~/Library/Application Support/ClipboardArchive/ClipboardArchive.lock
```

The archive and index can be overridden with:

```text
CLIPBOARD_ARCHIVE_ARCHIVE_ROOT
CLIPBOARD_ARCHIVE_INDEX_PATH
CLIPBOARD_ARCHIVE_APPLICATION_SUPPORT_ROOT
```

Aaron's current LaunchAgent pins those two values to:

```text
/Users/legacy/Development/AI-Hub-Archive/clipboard-history
/Users/legacy/Development/AI/data/clipboard-history/indexes/clipboard-search.sqlite
```

The Application Support override isolates settings, the instance lock, and the
`UserDefaults` suite for development fixtures; release LaunchAgents normally
use the default paths and preference domain.

## Archive Format

Accepted events are appended as JSON lines under:

```text
raw/YYYY/MM/YYYY-MM-DD_clipboard-events.ndjson
```

Text larger than the configured inline threshold is stored separately under:

```text
raw/YYYY/MM/YYYY-MM-DD_large-items/
```

The event record holds a relative body path, content hash, preview, source-app
metadata, size counts, privacy label, allowed local uses, and the original
seven-day UI visibility timestamp retained for archive-format compatibility.

Blocked events retain timestamp, source-app metadata, and a machine-readable
reason. They do not include clipboard text.

Deletion rewrites matching event content to a tombstone, removes any referenced
large-body file, appends a deletion-ledger record, and deletes the matching row
from the derived index. It does not erase backups or filesystem snapshots that
already captured the data.

Every event-provided body path is resolved component by component beneath the
archive root. Absolute paths, traversal components, and symlink escapes are
rejected before read or deletion. App-created directories use mode `0700` and
files use mode `0600`.

## Search And Retention

The clipboard window has two scopes. This Window loads recent records from
the user-selected working window (1, 7, 14, or 30 days) and filters them in
memory by query and All/Text/Links/Code/Images/Files type. All History
reads the derived FTS index only — full-archive search with date, app, and
type filters, debounced on a background queue; it never scans NDJSON on
the UI thread. Duplicate grouping and collection filtering apply in both
scopes as presentation after filtering. The menu's five quick-copy items
remain a short recent view, and the quick picker serves keyboard-first
recall from a warm in-memory cache invalidated on every archive mutation.

The CLI's archive search scans NDJSON plus contained body files. The separate
SQLite FTS index is derived data and stores searchable content in plaintext.
Each accepted capture upserts one row in a short SQLite transaction; SQL is
streamed to `/usr/bin/sqlite3` over standard input so clipboard text never
appears in process arguments. An index failure returns a maintenance status but
does not fail or roll back the archive write.

Full index rebuild remains the recovery path. It invokes `/usr/bin/sqlite3`,
validates a private sibling temporary database with `quick_check`, and
atomically replaces the prior index only after success. An owner-only
cross-process lock serializes rebuild, upsert, and deletion operations so an
external repair cannot replace the database during a capture update.

The selected history window is a display boundary, not a deletion policy.
Storage modes can retain 10 items, 50 items, or the full archive. The limited
modes physically prune older content after accepted captures.

## Privacy And Trust Boundaries

Filtering happens before archive writes, with a fixed precedence (Slice 5):
1. the concealed/transient pasteboard-type denylist (nothing overrides it),
2. the built-in password-manager lists (a `normal` per-app rule cannot
   override them),
3. explicit per-app privacy rules (`block` / `store-no-index` / `normal`;
   unknown modes fail closed as `block` and round-trip losslessly),
4. the legacy user exclusion lists (only when no explicit rule exists),
5. `SecretDetector` content inspection (runs even for `store-no-index`
   apps).

`.restricted` label semantics are binding: stored, visible, never
searchable. `ClipboardSuppression` is still the ONE suppression gate file,
now with two named predicates — `isSuppressed` (visibility, unchanged) and
`isIndexExcluded` (tombstone label OR `.restricted` label OR the manual
"restricted" annotation override). Index writers (capture upsert, rebuild)
and the CLI archive searcher route through `isIndexExcluded`; readers never
do. The capture upsert deletes-instead-of-inserts for excluded events so a
re-copy can never resurrect an index row; manual overrides key on content
hash in the annotations sidecar so archive lines are never rewritten.

Timed private mode returns from the capture poll BEFORE the pasteboard is
read — no stored events and no blocked-event lines, structurally. Exiting
private mode or a pause resynchronizes `lastChangeCount`/`lastContentHash`
from the current pasteboard without ingesting (the Slice 5 fix for the
pause retro-capture bug). `ClipboardCaptureGate` in Core is the pure,
tested decision function behind this.

Bulk deletion composes the single pruner core (`pruneCore`): one compiled
predicate, an index `delete(eventIDs:)` batched BEFORE tombstoning
(fail-closed ordering), per-event ledger records with a
`bulk-<criteria>` reason, and truthful reclaim accounting (stat'ed body
files plus the signed original-line minus tombstone-line byte delta,
computed identically in dry-run and execute modes). The expiry sweeper
(`ClipboardExpirySweeper`) resolves due content hashes to live occurrence
ids and executes them through the same engine with reason
`expired-sensitive`; enforcement points are launch, a 30-minute timer, and
surface opens — never the capture poll and never read-time hiding.

The current filter blocks a hard-coded set of concealed/transient
pasteboard types, password-manager/keychain apps, user-configured
exclusions and rules, and credential-like text recognized by
`SecretDetector`.

This is risk reduction, not a guarantee. Browser password fields, unknown
credential formats, incorrect source attribution, and clipboard changes
overwritten between polling intervals remain outside the app's reliable
visibility.

Accepted archive and index content are plaintext and readable by processes with
the same macOS user permissions. CryptoKit is used for hashing, not encryption.
Settings are also plaintext. New and saved settings files use mode `0600`;
loading a legacy regular settings file repairs broader permissions, while a
file that cannot be repaired falls back to capture-off defaults. A symlinked
settings path is rejected rather than followed.

## Rich Content Containment

Rich bodies (image bytes, RTF, spilled file lists) store as body files
under the same `raw/YYYY/MM/*_large-items/` layout with type-derived
extensions; `richContent.bodyPath` is relative and containment-checked
exactly like text bodies. File-type clips store metadata only — names,
paths, sizes — never file contents. Images above the configurable cap
(default 10 MiB) are blocked before any decode with a visible reason.
Text-only lines keep stamping schema version 1 byte-identically; only
events carrying `richContent` stamp version 2.

## Encrypted Backup

`backup create` produces a CLIPBAK1 container: PBKDF2-HMAC-SHA256
(runtime-calibrated, 600k-iteration floor) feeding HKDF-derived subkeys,
a sealed manifest whose AAD binds the plaintext KDF header, and 4 MiB
AES-GCM chunks with positional AAD so drops, reorders, and splices fail
hard. Import runs three phases — authenticate and stage into a hidden
0700 directory, plan (one planner shared by dry-run and execute), then a
journaled ledger-first commit with pre-image rollback. Merge restores
honor the local deletion ledger; locally deleted events and their rich
bodies are never resurrected. The derived index is excluded and rebuilt
after import.

## Current Startup Behavior

The app acquires an exclusive file lock before creating its menu-bar UI. A
second executable exits without starting another polling loop.

Launch at login is user-controlled and off by default. The Settings toggle
wraps `SMAppService.mainApp` (macOS 13+): state is re-read whenever the
card shows, `.requiresApproval` renders an approval message with a Login
Items shortcut, and `.notFound` (development builds outside a normal app
location) disables the toggle with an honest explanation. The installer's
LaunchAgent remains a separate mechanism; `docs/INSTALL.md` tells users to
pick one. Registration never happens automatically.

On a new profile with no settings file, capture defaults off. A first-run
window discloses plaintext storage and filter limits, shows the archive path,
and requires the user to choose no capture, a last-50 archive (recommended), or
the full archive. Existing settings migrate as already-onboarded without
changing their capture or retention behavior.

## Permission Gates

Starting live capture, installing or changing login behavior, replacing the
running app, or changing Aaron's source-retention policy requires explicit
approval and the AI Hub archive workflow.

Safe package-level development uses:

```bash
/usr/bin/xcrun swift build
/usr/bin/xcrun swift test
/usr/bin/xcrun swift run clipboard-archive-checks
/usr/bin/xcrun swift run clipboard-archive self-test
```

Do not run the manual monitor or replace `dist/ClipboardArchive.app` while the
installed live instance is in use without an explicit operational plan.

Debug UI automation requires both the archive and Application Support roots to
be explicit `/tmp` paths. It can author synthetic fixtures and render the
history, settings, or onboarding surface, then terminates. The guard exists so
visual testing cannot silently point at a real archive.
