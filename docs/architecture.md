# Clipboard Archive Architecture

Last verified against source: 2026-07-29

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
  -> ClipboardPrivacyFilter
       -> blocked-event metadata only
       -> accepted StoredClipboardEvent
  -> append-oriented NDJSON archive
       -> inline text, or a same-day large-body file
  -> incremental derived SQLite FTS upsert
  -> recent menu/window reader

CLI
  -> search / redact / prune / health / manifest / index repair
  -> the same core library and archive format
```

`ClipboardArchiveCore` owns the data model, filtering, archive reader/writer,
redaction, pruning, health reporting, settings, and the derived index.

`ClipboardArchiveMenuBar` owns pasteboard polling, source-app attribution,
pause/storage controls, recent-history UI, settings, and the single-instance
file lock.

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

The clipboard window loads recent records from the user-selected working
window: 1, 7, 14, or 30 days. Its in-memory filters combine a search query with
All, Text, Links, or Code content-type selection. These controls filter loaded
event preview/source/type metadata; they do not search the full archive or
large-body contents. The menu's five quick-copy items remain a short recent
view.

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

Filtering happens before archive writes. The current filter blocks a hard-coded
set of concealed/transient pasteboard types, password-manager/keychain apps,
user-configured exclusions, and credential-like text recognized by
`SecretDetector`.

This is risk reduction, not a guarantee. Browser password fields, unknown
credential formats, incorrect source attribution, and clipboard changes
overwritten between polling intervals remain outside the app's reliable
visibility.

Accepted archive and index content are plaintext and readable by processes with
the same macOS user permissions. CryptoKit is used for hashing, not encryption.

## Current Startup Behavior

The app acquires an exclusive file lock before creating its menu-bar UI. A
second executable exits without starting another polling loop.

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
