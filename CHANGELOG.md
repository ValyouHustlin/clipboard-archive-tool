# Changelog

## Unreleased - 2026-07-30 (bulk management, privacy upgrades, dashboard)

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

## Unreleased - 2026-07-29

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
