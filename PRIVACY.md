# Privacy

Clipboard Archive is local-first.

- Clipboard contents are stored on the Mac where the app is installed.
- The app does not send clipboard contents to cloud services.
- The app has no network sync, telemetry, analytics, crash reporting, or
  in-app update checks.
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
  content, removes older body files, records deletion markers, and rebuilds the
  local SQLite search index.
- Storage mode can be set to remember 10 items, remember 50 items, or keep a
  full archive. Recent-only modes automatically prune older content.
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

`CLIPBOARD_ARCHIVE_APPLICATION_SUPPORT_ROOT` exists for isolated development
profiles and changes the settings and instance-lock root.

Known limits:

- macOS exposes clipboard changes as a pasteboard change count, not a queue.
  A value overwritten before the app polls cannot be recovered.
- Source app attribution is best-effort.
- Browser password fields are not reliably detectable without deeper
  Accessibility inspection.
- Unsigned local builds may require macOS Gatekeeper approval on first launch.
- Accepted clipboard content and the derived SQLite index are plaintext local
  files. CryptoKit is used for hashing, not archive encryption.
- Owner-only file permissions reduce accidental disclosure but do not protect
  against processes running as the same macOS user.
- Deletion and pruning affect this app's live archive and derived search index,
  not external backups or filesystem snapshots that already captured files.
