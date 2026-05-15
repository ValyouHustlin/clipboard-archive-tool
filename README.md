# Clipboard Archive

Clipboard Archive is a local-first macOS menu bar app that records useful
clipboard history without sending clipboard contents to cloud services.

It has two jobs:

1. Keep a calm, searchable 7-day working view in the app.
2. Preserve accepted clipboard events indefinitely in a durable local archive
   that AI agents or local tools can search later.

## Features

- Native macOS menu bar app.
- Continuous local text clipboard capture.
- Search, recent items, copy-back, manual delete/redact, pause/resume, and app
  exclusions.
- Settings window for permanent archive tracking, visible item count, poll
  interval, excluded apps, and storage paths.
- Password-manager and credential-like content blocking.
- Append-oriented NDJSON archive with metadata.
- Large clipboard bodies stored as separate local files.
- Rebuildable SQLite FTS search index.
- Daily manifests and health reports.
- Install/update scripts for copying releases to other Macs.
- No network sync, telemetry, analytics, crash reporting, or in-app update
  checks.

## Install A Release

Install or update from the latest GitHub Release:

```bash
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/ValyouHustlin/clipboard-archive-tool/main/scripts/install-latest-github-release.sh)"
```

That command downloads the release zip, verifies `SHA256SUMS`, installs the
menu bar app and CLI, and registers the LaunchAgent login item.

Manual file handoff also works. Download or copy a release folder, then run:

```bash
./install.sh
```

Default per-user install locations:

```text
~/Applications/ClipboardArchive.app
~/.local/bin/clipboard-archive
~/Library/LaunchAgents/app.clipboardarchive.plist
~/Library/Application Support/ClipboardArchive/Archive/clipboard-history
~/Library/Application Support/ClipboardArchive/Indexes/clipboard-search.sqlite
```

To update, copy a newer release folder and run `./install.sh` again. Existing
archive data remains in place.

The installed app operates fully offline. It does not need internet access for
capture, search, archive storage, health checks, or updates by file handoff.

See [docs/INSTALL.md](docs/INSTALL.md).

## Build A Shareable Package

From the repository root:

```bash
./scripts/package-release.sh
./scripts/validate-release.sh releases/ClipboardArchive-0.1.0-macos-arm64
```

Outputs:

```text
releases/ClipboardArchive-<version>-macos-<arch>/
releases/ClipboardArchive-<version>-macos-<arch>.tar.gz
releases/ClipboardArchive-<version>-macos-<arch>.zip
```

Versioned build:

```bash
CLIPBOARD_ARCHIVE_VERSION=0.1.1 CLIPBOARD_ARCHIVE_BUILD=2 ./scripts/package-release.sh
```

See [docs/DISTRIBUTION.md](docs/DISTRIBUTION.md).

Update guidance lives in [docs/UPDATES.md](docs/UPDATES.md). The app itself
does not check the internet for updates.

GitHub release guidance lives in [docs/GITHUB.md](docs/GITHUB.md). The GitHub
updater is a separate human-run Terminal helper; it is not part of app runtime.

## Development

```bash
swift run clipboard-archive-checks
swift run clipboard-archive self-test
swift run clipboard-archive monitor --duration 30
swift run clipboard-archive search "example" --limit 10
swift run clipboard-archive repair-index
swift run clipboard-archive index-search "example" --limit 10
swift run clipboard-archive health
swift run clipboard-archive write-manifest
./scripts/build-menu-bar-app.sh
./scripts/stress-clipboard-monitor.sh
./scripts/stress-menu-bar-app.sh
./scripts/check-archive-integrity.sh
./scripts/scale-benchmark.sh 50000
```

The installed app itself has no network behavior. GitHub is only used by
human-run install/update commands.

## Data Model

Archive root:

```text
raw/YYYY/MM/YYYY-MM-DD_clipboard-events.ndjson
manifests/YYYY-MM-DD_manifest.json
deletion-ledger/
```

Each stored event includes capture time, source app metadata, content type,
hash, byte/line counts, privacy label, allowed local uses, preview text, and
either inline content or a relative path to a large body file.

The SQLite FTS index is derived data and can be rebuilt from the archive.

## Privacy

Clipboard Archive is intentionally transparent and controllable:

- Local-only storage by default.
- No network sync.
- Password managers and obvious secrets are blocked.
- Blocked sensitive events do not store raw content.
- Delete/redact removes inline content, large body files, and derived SQLite
  search rows. Timeline metadata remains with a deletion marker.
- Pause and exclusion controls are available in the menu bar UI.
- Permanent archive tracking can be turned off in Settings. When it is off,
  clipboard changes are not written to the durable archive.

See [PRIVACY.md](PRIVACY.md).

## Capture Limits

The app polls `NSPasteboard` every 0.2 seconds. Normal human copy actions should
be captured reliably. Machine-speed clipboard churn can overwrite values before
the app polls because macOS exposes a change counter, not a queue.

Source app attribution is best-effort and based on active/frontmost app state.

## License

MIT. See [LICENSE](LICENSE).
