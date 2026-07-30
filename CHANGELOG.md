# Changelog

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
