# Clipboard Archive

Clipboard Archive is a local-first macOS menu bar app that records useful
clipboard history without sending clipboard contents to cloud services.

It is intentionally a focused open-source tool, not a hosted service or a
subscription product. It has two jobs:

1. Keep a calm, searchable working view in the app, configurable from the last
   24 hours through the last 30 days.
2. Preserve accepted clipboard events indefinitely in a durable local archive
   that AI agents or local tools can search later.

## Features

- Native macOS menu bar app.
- Split-view history window with This Window and All History scopes:
  working-view browsing plus full-archive index search with date, app, and
  type filters, rich clip rows, full-text preview, multi-select copy, and
  local delete/redact controls.
- Quick picker on a configurable global shortcut (off by default): a
  floating, keyboard-first panel with copy-back that needs no permissions
  and an optional Accessibility-based direct paste.
- First-run privacy disclosure with capture-off, last-50, or full-archive
  choices before the first item can be stored.
- Continuous local clipboard capture: text plus optional rich formats —
  images (size-capped), file references (metadata only), rich text, colors,
  and titled links, each with faithful copy-back.
- Pins that survive retention pruning, tags, collections, and snippets,
  stored in a local sidecar keyed on content so they survive re-copies.
- Duplicate grouping with copy counts and expandable occurrences.
- Clip actions: copy as plain text, strip formatting, clean tracking
  parameters from URLs, normalize whitespace, join clips, and
  edit-before-copy (edits are copied, never saved to history).
- Privacy controls: password-manager and credential-like content blocking,
  per-app rules (Block / Store-don't-index / Normal), manual restricted and
  expiring clips, timed private mode that never reads the pasteboard, pause
  and app exclusions, and plain-language blocked-item explanations.
- Bulk cleanup with truthful previews — the preview and the delete share
  one code path, so counts and reclaimed bytes match exactly.
- Storage & Health dashboard: sizes, counts, blocked items, index rebuild,
  integrity verification, and preview-first cleanup.
- Encrypted local backup and restore (passphrase-protected AES-GCM) with a
  merge-aware import that honors local deletions.
- Branded, color-coded settings for capture, retention, a 1/7/14/30-day
  history window, history size, polling, privacy rules, shortcuts,
  launch-at-login, and local-storage details, plus an About section with
  version and format facts.
- Optional launch at login via macOS Login Items (off by default, never
  enabled automatically).
- Append-oriented NDJSON archive with metadata and versioned, tolerant
  event decoding.
- Large clipboard bodies stored as separate local files.
- Incrementally maintained, rebuildable SQLite FTS search index.
- CLI for search, prune, bulk cleanup, health, backup, and index repair.
- Storage modes: remember 10 items, remember 50 items, or keep a full archive.
- Daily manifests and health reports.
- Install/update scripts for copying releases to other Macs.
- No network sync, telemetry, analytics, crash reporting, or in-app update
  checks. Updates are manual via the GitHub Releases page.

## Install A Release

Download or copy a release folder, then run:

```bash
./install.sh
```

The installer verifies bundled checksums before it stops an existing instance,
stages the replacement app, and restores the previous app and LaunchAgent if
the new app does not remain running. Checksums detect damaged or mismatched
files; they do not prove publisher identity. Public distribution still requires
Developer ID signing and notarization.

## Update Another Mac

The optional Terminal updater can fetch the latest GitHub Release:

```bash
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/ValyouHustlin/clipboard-archive-tool/main/scripts/install-latest-github-release.sh)"
```

Review the downloaded script before using this convenience command. The update
preserves local clipboard history, settings, and indexes on that Mac. It
replaces only the app bundle, CLI, and LaunchAgent definition.

To pin a specific version:

```bash
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/ValyouHustlin/clipboard-archive-tool/main/scripts/install-latest-github-release.sh)" -- ValyouHustlin/clipboard-archive-tool v0.2.0
```

After install/update:

```bash
~/.local/bin/clipboard-archive health
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

## Project Direction

Clipboard Archive is being maintained as Aaron's polished daily-use utility and
an open-source download for anyone who finds that workflow useful. There is no
current plan to turn it into a paid clipboard product, add cloud accounts, or
compete on App Store growth.

The prior market analysis remains available as historical context in
[docs/market-positioning-and-business-analysis.md](docs/market-positioning-and-business-analysis.md);
it is not the current product roadmap.

For a short restart guide for the next agent session, see
[docs/NEXT_SESSION_HANDOFF.md](docs/NEXT_SESSION_HANDOFF.md).

## Build A Shareable Package

From the repository root:

```bash
./scripts/package-release.sh
./scripts/validate-release.sh releases/ClipboardArchive-0.2.0-macos-arm64
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
swift test
swift run clipboard-archive-checks
swift run clipboard-archive self-test
swift run clipboard-archive monitor --duration 30
swift run clipboard-archive search "example" --limit 10
swift run clipboard-archive redact EVENT_ID
swift run clipboard-archive prune --until 2026-01-01 --dry-run
swift run clipboard-archive prune --until 2026-01-01
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

The SQLite FTS index is derived data. Accepted captures update it
incrementally; it can still be rebuilt from the archive as a recovery path.

## Privacy

Clipboard Archive is intentionally transparent and controllable:

- Local-only storage by default.
- No network sync.
- Password managers and obvious secrets are blocked.
- Standard concealed/transient pasteboard types are blocked before storage.
- Blocked sensitive events do not store raw content.
- New profiles start with capture off and require an explicit first-run
  retention choice.
- App-created archive directories use owner-only permissions (`0700`) and
  files use owner-only permissions (`0600`).
- Delete/redact removes inline content, large body files, and derived SQLite
  search rows. Timeline metadata remains with a deletion marker.
- Prune can periodically redact older content and rebuild local search.
- Pause and exclusion controls are available in the menu bar UI.
- Long-term storage can be switched off from the menu or Settings. Recent-only
  modes automatically prune older content while keeping the app useful.

See [PRIVACY.md](PRIVACY.md) and [SECURITY.md](SECURITY.md).

## Capture Limits

The app polls `NSPasteboard` every 0.2 seconds. Normal human copy actions should
be captured reliably. Machine-speed clipboard churn can overwrite values before
the app polls because macOS exposes a change counter, not a queue.

Source app attribution is best-effort and based on active/frontmost app state.

## License

MIT. See [LICENSE](LICENSE).
