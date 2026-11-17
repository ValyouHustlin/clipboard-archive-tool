# Privacy

Clipboard Archive is local-first.

- Clipboard contents are stored on the Mac where the app is installed.
- The app does not send clipboard contents to cloud services.
- The app has no network sync, remote analytics or crash reporting, and the
  app process that reads the clipboard makes no network request at all.
- Updates (disk image releases built with an update feed only) are done by a
  separate helper app that has no clipboard code. It sends an HTTPS request
  for the update feed and for the update file, with the app name, the app
  version and the Sparkle version in the user agent, and nothing else: no
  system profile, no clips, no identifier. See [docs/UPDATES.md](docs/UPDATES.md).
- After install, normal capture/search/archive operation works without an
  internet connection.
- Password managers and credential-like content are blocked by default.
- Standard concealed, transient, and password-manager pasteboard types are
  blocked before content storage.
- Blocked sensitive events are recorded without raw content.
- New profiles start with capture off. First run explains plaintext storage and
  filter limits before offering no capture, last-50, or full-archive storage.
- App-created archive directories and files are restricted to the owning user
  (`0700` directories and `0600` files).
- Manual delete/redact removes inline content, removes large body files,
  records a deletion marker, and purges the item from the local SQLite search
  index. Non-content timeline metadata remains so the archive can show that an
  item existed without retaining the copied text.
- Periodic pruning is available through the CLI. Pruning redacts older archive
  content, removes older body files, records deletion markers, and removes the
  matching rows from the local SQLite search index. Pinned clips are kept
  unless you pass `--include-pinned`.
- Storage mode can be set to remember 10 items, remember 50 items, or keep a
  full archive. Recent-only modes automatically prune older content; pinned
  clips are kept outside the limit.
- Capture can be turned off from the Settings window. When it is off, new
  clipboard changes are not written to durable history.
- Per-app privacy rules extend the exclusion list with three modes. `block`
  stores nothing (an audit line without content records that something was
  blocked). `store-no-index` stores the clip with the `restricted` label:
  it stays visible in History but never enters the search index. `normal`
  restores default handling. A `normal` rule can never override the built-in
  password-manager protection or the pasteboard-type denylist, and an
  unknown rule mode written by a newer version evaluates as `block` (fail
  closed) while round-tripping unchanged. Saving a `store-no-index` rule
  also keeps the app in the plain exclusion list so OLDER versions of the
  app block it outright — stricter, never looser.
- Restricted means stored, visible, never searchable. Marking a clip
  "Restricted" by hand records a sensitivity override keyed by content hash
  in the local annotations file, immediately removes its occurrences from
  the search index, keeps re-copies of the same content out of the index,
  and never rewrites archive lines. Clearing the override re-indexes the
  content. Restricted clips show an eye-slash badge; the All History search
  scope notes that restricted clips are hidden from search.
- Expiring sensitive clips: an expiry can be set on a clip (1 hour / 1 day /
  7 days). When it passes, every stored copy of that content is deleted —
  including pinned copies; the app warns that expiry overrides pin
  protection when it is set. Enforcement runs at app launch, every 30
  minutes, and when a history surface opens — never on the capture poll —
  so an expired clip can remain briefly visible between enforcement points
  (and while the app is not running). It is deleted at the next enforcement
  point.
- Timed private mode (15 minutes / 1 hour / until tomorrow) stops the
  capture loop BEFORE the pasteboard is read: while it is active nothing is
  evaluated, stored, or recorded — not even blocked-event metadata lines.
  When private mode or a pause ends, the app resynchronizes its
  change-tracking against the current pasteboard without ingesting, so the
  last item copied during the gap is never captured retroactively.
- Bulk deletion (by date, app, type, or sensitivity) always shows a dry-run
  preview computed by the same code that executes — event count and
  reclaimed bytes — and names that deletion cannot be undone. Pinned clips
  are exempt unless "include pinned" is explicitly chosen and separately
  confirmed. Every bulk deletion writes per-event ledger records with a
  machine-readable reason.
- The Storage & Health dashboard explains recent blocked events in plain
  language (which protection fired) without ever having stored the blocked
  content.
- Archive and index locations are controlled by environment variables in the
  LaunchAgent:
  - `CLIPBOARD_ARCHIVE_ARCHIVE_ROOT`
  - `CLIPBOARD_ARCHIVE_INDEX_PATH`

`CLIPBOARD_ARCHIVE_APPLICATION_SUPPORT_ROOT` exists only for isolated
development runs. Besides the settings and instance-lock root, it moves
preferences into a file, reads the clock from a file, and binds the app to a
private named pasteboard, so an app started with it captures nothing from the
real clipboard. Never set it in a LaunchAgent.

Known limits:

- macOS exposes clipboard changes as a pasteboard change count, not a queue.
  A value overwritten before the app polls cannot be recovered.
- Source app attribution is best-effort.
- Browser password fields are not reliably detectable without deeper
  Accessibility inspection.
- Unsigned local builds may require macOS Gatekeeper approval on first launch.
- Accepted clipboard content and the derived SQLite index are plaintext local
  files. CryptoKit hashes clipboard contents and encrypts the backups you
  create; the archive itself is not encrypted at rest.
- Owner-only file permissions reduce accidental disclosure but do not protect
  against processes running as the same macOS user.
- Deletion and pruning affect this app's live archive and derived search index,
  not external backups or filesystem snapshots that already captured files.

## Content-free local usage diagnostics

`<archive root>/usage/events.ndjson` records feature use and operational
outcomes locally. Events: `app_start`, `search`, `quick_picker`, `copy_back`,
`capture`, `blocked`, `index_rebuild`, `error`. Allowed outcomes: `success`,
`hit`, `miss`, `failed`, `excluded`, `unavailable`. Scopes: `application`,
`all_history`, `this_window`, `quick_picker`, `archive`, `index`.

The exact fields are `schema`, `timestamp` (UTC ISO 8601 milliseconds),
`version` (numeric components), `build` (integer), `event`, `outcome`, `scope`,
`count`, `durationMs`, `bytes`. Unknown bundle version/build are empty/zero;
unmeasured durations/sizes are zero. No content, previews, query strings,
identifiers, hashes, source-app names, paths, or raw errors enter this log.
Timestamps and counts still reveal when the app is used, so the records remain
private local data. Logging also records app/feature use while capture is off;
it does not read the pasteboard for diagnostics.

Files are owner-only (`0600`, directory `0700`), capped at 1 MiB each, with
five retained files total. Rotation names are `events.1.ndjson` through
`events.4.ndjson`. Writes are best effort; a busy lock or disk error may drop
a record. Records are never sent over the network and are excluded from
backup exports. Deleting a clip does not delete aggregate diagnostic rows,
which cannot identify the clip.

## Content-free operational log

`~/Library/Logs/ClipboardArchive/operational.ndjson` records what the app and
the command line were DOING: launches and stops, a 30-minute heartbeat,
capture failures by reason class, refused second instances, settings
fallbacks, index rebuilds and failed index updates, retention prunes, expiry
sweeps, store-pointer publishing, and one row per CLI invocation. With
`CLIPBOARD_ARCHIVE_APPLICATION_SUPPORT_ROOT` set, it lives under `<that
root>/Logs/` instead.

Every row carries `schema`, `timestamp` (UTC ISO 8601 milliseconds), `pid`,
`version`, `build`, `level`, `component`, `code`, `errno`, `count`,
`durationMs`, `bytes`, `polls`, `captures`, `rssBytes`, `verb` (on a
`cli_command` row, `count` is the exit code). Each textual
field is a closed enum defined in the source, and the recording API accepts no
free-form string, no `Error` and no path — so clipboard content, previews,
queries, identifiers, hashes, source-app names, file names and raw error
messages cannot enter this log, by construction rather than by filtering. A
capture failure is recorded as an errno class (for example 13 for permission
denied), never as a message.

Timestamps, counts and memory figures still say when the app ran and how much
it did, so these records remain private local data. Files are owner-only
(`0600`, directory `0700`), capped at 2 MiB each, five retained
(`operational.1.ndjson` through `operational.4.ndjson`). Writes are best
effort. Records are never sent over the network and are excluded from backup
exports. `clipboard-archive logs` prints them locally.
