# Changelog

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
