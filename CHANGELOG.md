# Changelog

## 0.4.0 build 10 - 2026-10-03

- Ship as a disk image you drag to Applications. `scripts/release.sh` builds
  the app, signs it, wraps it in a disk image with an Applications shortcut,
  writes the image's SHA-256 beside it, and takes these release notes from
  this file. It refuses before building when a precondition is missing: a
  CHANGELOG entry for the version, a clean working tree, or, for
  `--sign developer-id`, a Developer ID certificate in the keychain.
- Update in place. A separate helper inside the app,
  `Clipboard Archive Updater`, checks for, downloads and installs new
  versions with Sparkle 2. The app that reads the clipboard still makes no
  network request and links no updater; the helper links no clipboard code.
  `scripts/check-local-only.sh` checks both halves of that split. Every
  update must carry an Ed25519 signature from the release key, the feed
  itself must be signed, the request sends no system profile, and a copy
  built without a feed never checks at all. "Check for Updates…" is in the
  menu; the helper also runs from a terminal with `--unattended`.
  The feed signature requirement never lapses, and a feed URL set in user
  defaults is ignored.
- Say when the launch agent would start more than one app. A login item that
  hands `open` two app paths starts two copies; `status` read only the first
  path and called it healthy.
- Read the release version and build number from this file in every release
  script, instead of a literal in each.

## 0.3.0 build 9 - 2026-09-18

- Say when a run is only half isolated. Pinning the archive and index into a
  scratch directory without also setting the application-support root gave a
  run whose stores were scratch while its preferences, pasteboard, clock seam
  and log directory stayed on the real ones, and nothing said so. The command
  line now writes one sentence to standard error when it sees that, and
  `status` reports the archive root, the index path, where each was resolved
  from, and the support root it actually used. A launch agent pinning the real
  paths is not affected: the check looks at whether the path is scratch, not
  at whether the variable is set.
- Report a paused capture instead of skipping it. A pause disarmed every check
  that says capture has stopped, so a machine with capture switched on and a
  pause running could answer "no problems" while nothing was being archived.
  A pause is now reported with how much longer it has to run, and a stored
  pause is bounded to seven days, which no pause set from the menu can reach.

## 0.3.0 build 8 - 2026-09-15

Packaged but never installed; its contents ship in build 9.

- Read the archive as UTF-8 so `status` answers in seconds rather than tens of
  seconds on a large archive, with a fallback that still reads a file written
  in another encoding.
- Repair what certification found: an index being read while it is busy is no
  longer reported as damaged, a child process's exit code is no longer
  confused with its wait status, and a loader child no longer inherits a
  blocked signal mask across exec.
- Document the pasteboard opt-out beside the isolation seams it belongs to.

## 0.3.0 build 7 - 2026-09-15

- Embed the standalone command-line version in its executable, so it reports
  the installed release without environment overrides or a neighboring app.
- Include the command reference in the release package and validate app and
  standalone command identity against the release manifest.

- Make the command line answer to a script. Every command now exits with a
  number that means one thing — 2 for a usage mistake, 3 for stores that are
  not there, 4 for problems found, 5 for work that finished with something
  worth saying — where almost everything used to be 0 or 1, and a misspelled
  command used to print the help and report success. Under `--json` a failure
  prints an error object on standard error carrying the same code.
- Add `status`, `verify`, `doctor`, `export`, `stats` and `version`. `status`
  answers whether capture is alive right now and takes the answer from the
  lock file rather than launchd, which reports the exit of the launcher and
  not the life of the app. `verify` compares what the archive holds against
  what the search index holds, in both directions. `doctor` runs the lot and
  says what it means in one page.
- Make `search` use the index and the matcher the history window uses, so the
  same query no longer reports different hits in the app and the terminal.
  `--scan` keeps the raw-archive reader for when there is no index to trust.
- Add `export`, which writes clips with their content to a file you name. It
  refuses standard output, refuses to overwrite without being told, writes
  owner-only, prints counts rather than content, and leaves out anything
  marked restricted, by label or by hand, along with anything deleted.
- Describe every command from one table, which drives `help`, `help VERB` and
  a generated `docs/CLI.md`; a test regenerates the reference and fails if the
  committed copy has drifted.
- Stop letting a forgotten argument reach for the real store. Nine core types
  filled in the default archive index — and in one case the default settings
  file — when a caller did not pass one, so a command or a test operating on a
  scratch archive could quietly write the user's own. Those defaults are gone,
  which turned four such call sites into compile errors: two in the checks
  binary, one writing manifests, and the backup importer reading settings.

- Open the history window without freezing it. The working-window load read
  and decoded every day file on the main thread, which at a five-thousand-clip
  window was about a second of a window that does not draw, scroll or respond.
  The load now runs on the same background queue All History already used, the
  rows already on screen stay there while it runs, and a load overtaken by a
  newer one is discarded instead of putting stale rows back. A load that takes
  longer than a tenth of a second says "Loading…" beside the window name; one
  that beats that says nothing at all.
- Read day files about ten times faster. Reading a file into a `String` asks
  the system to work out its encoding first, which on a 280 KB day file cost
  27 ms against well under one to read the same bytes, and the archive is
  UTF-8 by construction. Reading five thousand clips went from about a second
  to about 150 ms, and every other reader of the archive gets the same cut.

- Cut the cost of storing a clip from about 70 ms to about 11 ms, and of
  opening All History from about 73 ms to about 1 ms. Every index read and
  write ran the `sqlite3` command as a separate process, and creating that
  process was 67 ms of the 70 — the database work itself was never the
  expense. The same statements now run inside the app. A full index rebuild
  still streams through `sqlite3`, which is the one job it is faster at.
- Keep capturing while a menu is held open, a window is being resized, or a
  modal panel is up. The poll timer ran in the default run-loop mode only, so
  those states stopped it outright, and because the pasteboard reports only its
  latest change, everything copied during the gap but the last item was gone.
  The poll and the expiry sweep now run in the common modes, as the heartbeat
  already did, and the process holds a user-initiated activity so App Nap
  cannot stretch their wakeups; an idle machine may still sleep.
- Keep an interrupted archive append from costing more than the row being
  written: a day file that does not end in a newline is closed with one before
  the next row, so a tail torn by a kill stays a single unreadable line instead
  of swallowing the following row; a short write or a full disk truncates back
  to the pre-row size and reports the reason class instead of leaving half a
  row behind.
- Detect a search index that was deleted or damaged while the app is running,
  instead of trusting it and quietly rebuilding an empty database that made
  All History shrink until the next restart. The file is checked before use,
  a search rebuilds it and returns complete results, and a capture hands the
  rebuild to the background rather than stalling on it.
- Fall back to the last known-good settings instead of defaults when the
  settings file cannot be read: the unreadable file is set aside as
  `settings.json.corrupt-<timestamp>` and `settings.json.bak`, written after
  every successful save, is loaded. Defaults would have turned capture off and
  replaced a chosen retention mode with "keep the latest 50".

- Add a content-free operational log with a heartbeat at
  `~/Library/Logs/ClipboardArchive/operational.ndjson` (2 MiB x 5, owner-only,
  following an injected application-support root). It records launches and
  stops, a 30-minute heartbeat carrying polls, captures, resident memory and
  time since the last capture, capture failures by errno class, refused second
  instances, settings fallbacks, index rebuilds and failed index updates,
  retention prunes, expiry sweeps, store-pointer publishing, and one row per
  CLI invocation with its verb and exit code. Every field is a number or a
  closed-enum value, so clipboard content cannot enter a row. Read it with the
  new `clipboard-archive logs` command (`--tail`, `--errors`, `--since`,
  `--json`). The heartbeat exists to make the one failure no event can show —
  an app that silently stopped running — visible.
- Report why a settings read fell back to defaults, so a corrupt settings file
  replacing the chosen retention mode is recorded instead of silent.

- Resolve the archive and the search index through one shared resolver, so
  the app and the command line always name the same stores. Each path is
  decided on its own: an explicit argument, then the environment variable,
  then the pointer file the app publishes at launch, then the default
  location. A terminal with none of the app's environment therefore reads
  the app's stores instead of a stale file at the default path. New
  `clipboard-archive stores` reports each resolved path with its source, the
  pointer's status, and any unused index file left at the default location;
  `health` reports the same sources alongside its existing fields.
- Fix an injected application-support root being ignored when deriving the
  default archive and index paths.

- Support a symlinked archive root: the root is resolved once before every
  containment test and directory walk, so history, search, health, and backup
  read an archive folder reached through a link exactly like the real
  directory. The `/private/tmp` and `/tmp` spellings of one root now agree.
- Report capture write failures in the menu instead of a dialog: the status
  line reads `Archive error: <reason>` with a `Last error` line carrying the
  reason class, time, and count since launch, capture keeps running, and the
  next successful capture clears it. Dialogs remain for user-initiated
  actions. Repeats of one reason within an hour only update the count.
- Give the scale benchmark its own search index so a benchmark run cannot
  rebuild the default index from synthetic rows.

- What's New onboarding: a once-per-version window listing the headline
  features (quick picker, all-history search, pins & snippets, private mode
  and app privacy rules, encrypted backup, storage & health) with deep
  links into Settings, History, and the Storage & Health dashboard. Shown
  after upgrading (tracked by a new tolerant `lastSeenAppVersion` settings
  key — settings files from older builds qualify exactly once) and as an
  optional, skippable second step after the unchanged first-run privacy
  choice. The seen-version is persisted the moment the window appears, so
  quitting with it open never causes a second showing.

## 0.2.0 build 6 - 2026-09-15

- Search literal case-insensitive substrings across full clip text in both
  history scopes, including text beyond the preview; punctuation stays literal.
- Share the native SQLite and window matcher without changing index schema.
- Bound search snippets before accumulating results.
- Add capped, content-free local usage diagnostics for search, copy, picker,
  capture, blocked items, rebuilds, application starts, and errors.
- Record pasteboard write outcomes for plain and rich copy-back.


## 0.2.0 - 2026-07-30

The complete 2026-07 feature expansion: twelve feature slices, two fixed
privacy bugs, and a round of review-driven hardening, all under the same
offline promise — the app runtime has no network code of any kind.

### Foundations

- Event schema versioning with tolerant decoding: every existing archive
  line decodes as version 1; text-only lines keep writing the byte-identical
  v1 shape; only events using v2 fields (rich content) stamp version 2.
  Unknown content types from newer builds decode instead of failing the
  line. An `archive-format.json` marker records the on-disk format.
- One suppression gate (`ClipboardSuppression`) now serves every read path;
  deletion-ledger reads are cached; retention pruning became incremental
  (no more full rewrite + full index rebuild per capture in recent-10/50
  modes); copying a clip back out of the app is no longer re-captured as a
  new event.
- Derived index schema v2 (`PRAGMA user_version`, content-hash and
  captured-at indexes, stored previews) with automatic rebuild on version
  mismatch. All SQL — including the legacy CLI search — now streams over
  stdin, so clipboard content never appears in process arguments.

### Features

- Quick picker: a floating, keyboard-first panel on a configurable global
  shortcut (default ⌥⌘V, off until enabled in Settings). Copy-back needs no
  permissions; direct paste is a separate opt-in that uses Accessibility
  and degrades to copy-back. Registration conflicts surface in Settings and
  the menu, never silently.
- Full-archive search in History: an All History scope over the FTS index
  with date, app, and type filters — plus the existing working-window view.
- Pins with retention protection: pinned clips survive recent-10/50 pruning
  and bulk cleanup unless "include pinned" is separately confirmed.
- Duplicate grouping with copy counts, first/last timestamps, and
  expandable occurrence rows, in both scopes.
- Tags, collections, and snippets, stored in a versioned sidecar
  annotations file keyed on content hash (annotations survive re-copies;
  the archive stays append-oriented). Snippets appear at the top of the
  quick picker and resolve to their newest live copy at commit time.
- Bulk management with truthful previews: preview and execute share one
  code path, so the confirmation's clip count and reclaimed bytes match the
  run exactly. History multi-select delete routes through the same engine.
- Rich clipboard formats: images (with a configurable size cap), file
  references (metadata only — never file contents), rich text, colors, and
  titled links, each with faithful copy-back of the original
  representations and per-kind detail rendering.
- Clip actions: copy as plain text, strip formatting, clean tracking
  parameters from URLs, normalize whitespace, join selected clips, and an
  edit-before-copy sheet. Edits are copied, never written to history; ⌥↩
  in the quick picker commits as plain text.
- Privacy upgrades: per-app rules (Block / Store-don't-index / Normal;
  unknown modes fail closed), manual Mark Sensitive with restricted
  (stored, visible, never searchable) and expiring clips, timed Private
  Mode that never reads the pasteboard while active, and plain-language
  blocked-event explanations.
- Storage & Health dashboard: extended overview computed off the main
  thread, recent blocked items with explanations, index rebuild and
  integrity verification with inline receipts, and preview-first cleanup.
- Encrypted backup and restore: passphrase-protected AES-GCM containers
  (PBKDF2-calibrated key derivation, tamper-evident chunking), a
  dry-run preview shared with execution, merge-aware restore that honors
  local deletions, and CLI `backup create/inspect/restore`.
- Daily-use polish: launch-at-login via macOS Login Items (SMAppService,
  off by default, never enabled automatically, honest status including the
  approval-pending and wrong-location cases), a refreshed first-run window
  that mentions the new capabilities without adding steps, an About section
  with app/format/schema versions and a copyable GitHub Releases URL
  (updates stay manual — the app never checks the internet), empty-state
  copy on every surface, and an accessibility/tooltip pass across the new
  controls.

### Fixed privacy bugs

- Pause retro-capture (pre-existing): resuming from a pause retroactively
  captured the last item copied while paused, because the pause exit never
  resynchronized pasteboard change tracking. All gate exits — manual pause,
  timed pause, and private mode — now resync without ingesting.
- Settings date decode (pre-existing): persisted ISO 8601 dates (timed
  pause, private mode, rule timestamps) could reset the whole settings file
  to defaults on load — silently turning capture back on and dropping
  exclusions. Dates now decode flexibly per field, and one malformed
  shortcut entry no longer resets unrelated settings.

### Review-driven hardening

- Deleted content can no longer be copied from a stale quick-picker cache;
  every archive mutation invalidates the warm caches.
- Fail-closed ordering for deletions: index rows are removed before
  tombstoning, so a crash cannot leave searchable content.
- In-process index locking fixed alongside the cross-process file lock;
  rebuilds no longer race capture upserts.
- Merge-restore no longer resurrects rich bodies of locally deleted events;
  restores honor the local deletion ledger.
- Restricted clips are badged on every surface (History, quick picker,
  menu); store-don't-index apps also stay in the legacy exclusion list so
  older builds block them outright (stricter, never looser).
- Bulk sheet close during an in-flight delete no longer skips cache
  invalidation; hotkey conflicts get a persistent menu warning.

## 0.2.0 development log - 2026-07-30 (bulk management, privacy upgrades, dashboard)

These notes were kept during the expansion and are summarized in the 0.2.0
entry above.

- FIXED PRIVACY BUG (pre-existing): resuming from a pause retroactively
  captured the last item copied while paused, because the pause exit never
  resynchronized the pasteboard change tracking. Pause exit — manual and
  timed — now resyncs without ingesting; the new timed Private Mode uses
  the same rule.
- Added timed Private Mode (15 minutes / 1 hour / until tomorrow): the
  capture loop returns before reading the pasteboard, so nothing is stored
  and no blocked-event metadata lines are written while it is active.
- Added per-app privacy rules with three modes: Block, Store don't index,
  and Normal. Store-don't-index clips are stored with the `restricted`
  label — visible in History, never searchable. A Normal rule cannot
  override the built-in password-manager protection. Unknown rule modes
  from newer builds evaluate as Block (fail closed) and round-trip
  losslessly.
- DOWNGRADE NOTE: saving a Store-don't-index rule ALSO keeps the app in the
  legacy exclusion list, so an older build of Clipboard Archive (which only
  knows that list) blocks the app outright — stricter, never looser. A
  Normal rule removes the legacy entry.
- Added manual "Mark Sensitive" controls: a Restricted toggle (stored,
  visible, hidden from search — occurrences leave the search index
  immediately and re-copies stay unindexed via content-hash annotations),
  expiring sensitive clips (1 hour / 1 day / 7 days; expiry overrides pin
  protection and says so), and Clear Sensitivity. Expiry is enforced at
  launch, every 30 minutes, and when history surfaces open.
- Added a bulk management engine with truthful previews: preview and
  execute share one code path, so the confirmation's clip count and
  reclaimed bytes match the run exactly. Criteria: date range, app, type,
  sensitivity, explicit selection. Pinned clips are exempt unless "include
  pinned" is separately confirmed. History multi-select delete now routes
  through the same engine.
- Added a Storage & Health dashboard window (replacing the health alert):
  extended overview computed off the main thread, recent blocked items with
  plain-language explanations, index rebuild with an inline receipt,
  integrity verification, and preview-first cleanup including the Bulk
  Cleanup sheet.
- Added CLI commands `bulk` (with `--dry-run`, `--json`, and criteria
  flags) and `sweep-expired`; `health` reports the new dashboard fields.
- Fixed a settings decode inconsistency: persisted ISO 8601 dates (timed
  pause, private mode, rule timestamps) now load correctly instead of
  resetting the settings file to defaults.

## 0.2.0 development log - 2026-07-29

- Rebuilt the history window as a searchable split view with rich
  source/type/time rows, a readable full-content detail pane, multi-selection,
  and clearer copy/delete feedback.
- Added a configurable 1/7/14/30-day history window, Text/Links/Code filters,
  and Copy/Delete context-menu actions.
- Rebalanced the history layout after daily-use review: search and clip status
  now live in a true sidebar, rows align consistently, actions stay with the
  selected clip, and preview height adapts to the amount of content instead of
  reserving a large empty pane.
- Simplified the menu-bar menu to five recent clips and direct History, Search,
  Pause, and Settings actions; moved occasional controls under Maintenance.
- Reworked first-run setup around a clear local-privacy explanation and three
  understandable retention choices.
- Reworked Settings into a branded, color-coded surface with an app mark,
  version/build information, properly padded cards, and focused capture,
  retention, timeline, exclusion, and local-storage sections.
- Existing settings files are repaired to owner-only `0600` permissions when
  loaded. Insecure files fail closed if they cannot be repaired, and symlinked
  settings paths are rejected without touching their targets.
- Added a debug-only, `/tmp`-guarded synthetic UI fixture and snapshot path so
  the app can be visually tested without opening a real clipboard archive.
- Kept synthetic UI snapshots from activating the debug app or stealing
  keyboard focus from the current foreground application.
- Added incremental SQLite FTS updates after accepted captures so local-agent
  search stays current without rebuilding the full archive. Index failures are
  reported as pending maintenance and never roll back a successful archive
  write; an owner-only cross-process lock serializes upserts, deletions, and
  recovery rebuilds.
- Recorded the owner direction: polished personal utility and open-source
  download, not a paid-product push.

- Added first-run privacy disclosure and explicit capture/retention choice;
  new profiles start with capture off and last-50 as the recommended option.
- Expanded to 28 synthetic Swift Testing tests for filtering, blocked-content
  non-retention, traversal and symlink containment, redaction boundaries,
  permissions, health windows, daily manifests, settings migration, and
  failure-safe SQLite rebuilds.
- Expanded credential and password-manager detection coverage.
- Honor standard concealed/transient pasteboard types before inspecting or
  storing content.
- Restricted app-created directories and files to owner-only permissions.
- Rejected unsafe archive body paths across read, search, redact, prune,
  health, and index operations.
- Corrected future-date health counts and day-scoped manifest counts.
- Made SQLite index replacement atomic and failure-preserving.
- Added isolated settings/lock roots for safe development and UI fixtures.
- Clarified that the configurable History window is a display boundary, not a
  deletion policy.
- Hardened packaging, checksum verification, update rollback, and live-instance
  guards without changing the installed instance.

## 0.1.2 - 2026-05-15

- Added storage modes for remembering 10 items, 50 items, or a full archive.
- Added a menu-bar toggle for turning full archive mode on/off.

## 0.1.1 - 2026-05-15

- Added `clipboard-archive prune` for periodic content cleanup.
- Added `SECURITY.md` with plaintext storage, best-effort filtering, signing,
  and pruning guidance.
- Re-signed the assembled app bundle during local release builds so `Info.plist`
  and the resource seal are bound to the ad hoc signature.

## 0.1.0 - 2026-05-15

- Added native macOS menu bar clipboard capture.
- Added 7-day UI working view with indefinite local archive.
- Added privacy filters for known password managers and credential-like text.
- Added local NDJSON archive with large body files.
- Added delete/redaction ledger.
- Added SQLite FTS derived index.
- Added health, manifest, repair, search, and full-pipeline CLI checks.
- Added release packaging with install/update scripts.
- Added Settings window with permanent archive tracking on/off and visible
  item count controls.
- Simplified menu organization and documented file-handoff updates.
- Added standalone GitHub release updater guidance without adding network
  behavior to the installed app.
