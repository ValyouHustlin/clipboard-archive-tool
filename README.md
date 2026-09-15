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
  choices before the first item can be stored, followed by an optional
  What's New tour.
- A What's New window that appears once per app version after an upgrade
  (never again for the same version, even if dismissed by quitting), with
  deep links into Settings, History, and Storage & Health.
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
- No network sync, remote analytics, crash reporting, or in-app update
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
~/Library/Application Support/ClipboardArchive/stores.json
```

### How the CLI finds the stores

The app and `clipboard-archive` resolve the archive folder and the search
index separately, each in the same order: an explicit `--archive-root` or
`--index-path` argument, then `CLIPBOARD_ARCHIVE_ARCHIVE_ROOT` or
`CLIPBOARD_ARCHIVE_INDEX_PATH`, then `stores.json`, then the default paths
above. `stores.json` is how a terminal with no environment reads the same
stores as the running app: the app writes it at launch, but only for paths it
was given explicitly, so starting the app by hand with no environment can
never redirect later commands, and a path that no longer exists is skipped.
Run `clipboard-archive stores` to see which source won for each path, and
whether another index file is sitting unused at the default location.

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
CLIPBOARD_ARCHIVE_VERSION=0.2.0 CLIPBOARD_ARCHIVE_BUILD=6 ./scripts/package-release.sh
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

The archive root may be a symlink; it is resolved once, so an archive folder
reached through a link reports the same events, health numbers, and search
results as the real directory.

Each stored event includes capture time, source app metadata, content type,
hash, byte/line counts, privacy label, allowed local uses, preview text, and
either inline content or a relative path to a large body file.

The SQLite FTS index is derived data. Accepted captures update it
incrementally, and both those writes and the searches that read them run
inside the app rather than through the `sqlite3` command, which is what makes
a capture cost about eleven milliseconds instead of seventy. A full rebuild still
uses `sqlite3` to stream the archive in, and remains the recovery path.

Day files are appended so that no interruption costs more than the row being
written. Before a row goes out, a file that does not end in a newline gets
one, so a tail torn by a kill or a power cut stays one unreadable line
instead of swallowing the row appended after it. The row itself is written in
full or not at all: a short write or a full disk truncates back to the size
the file had before it, and the failure is reported with the reason class.
There is no per-capture flush — the archive is an append-only log, and the
boundary repair is what makes an interrupted tail self-healing.

If the search index is deleted or damaged while the app is running, it is
detected rather than trusted: the file is checked before each use, and a
missing or failing one is rebuilt from the archive. A capture never waits for
that rebuild — the clip is already in the archive and the rebuild picks it
up — while a search waits and returns complete results.

## Search behavior

This Window searches complete clip text within the loaded history window.
All History searches the local index across the archive. Both match
case-insensitive literal substrings: `deve` and `vel` match `development`.
Whitespace-separated terms must all occur; `OR`, `NEAR`, `*`, quotes, `%`,
and `_` are ordinary text. Restricted clips remain browsable but do not
match a text search. File-reference searches include names, not full paths.
The index schema is unchanged; this update needs no rebuild.

All History runs in the background with a short debounce. Substring searches
scan indexed text, so larger archives can take longer than whole-word search.
Results are newest first and capped (normally 200); deletion filtering can
reduce a page below that cap.

## When a capture cannot be stored

A capture that cannot be written (disk full, permission denied, read-only
volume, missing archive folder) never opens a dialog. Capture keeps polling,
the menu status line reads `Archive error: <reason>`, and a `Last error` line
shows the reason class, the time, and how many have happened since that
reason was last cleared.
Repeats of the same reason within an hour only update that line. The next
successful capture clears it. Dialogs remain for actions a person started,
such as a manual index rebuild or a delete.

Settings are read with a last-known-good copy behind them. Every successful
save also writes `settings.json.bak`. If the settings file is ever
unreadable, it is set aside as `settings.json.corrupt-<timestamp>` and the
copy is loaded instead of defaults — defaults would turn capture off and
replace a chosen retention mode with "keep the latest 50". Defaults are used
only when there has never been a good copy.

## Local usage diagnostics

The app writes content-free usage records to `<archive root>/usage/events.ndjson`.
Events are `app_start`, `search` (hit/miss and history scope), `quick_picker`,
`copy_back`, `capture`, `blocked`, `index_rebuild`, and `error`.
Rows contain exactly `schema`, `timestamp` (UTC ISO 8601 with milliseconds),
`version` (numeric components), `build` (integer), `event`, `outcome`, `scope`,
`count`, `durationMs`, and `bytes`. CLI version/build are empty/zero when no
bundle metadata exists. Unmeasured durations and sizes are zero. Search rows
count completed filter evaluations, including refreshes, rather than unique
people or sessions; quick-picker rows count toggle requests.

Each file is capped at 1 MiB, with five files total (`events.ndjson` plus
`events.1.ndjson` through `events.4.ndjson`). The directory is `0700`, files
are `0600`. Busy locks or write failures drop diagnostics without interrupting
the action. These local records contain no clipboard text, previews, queries,
IDs, hashes, source apps, paths, or raw error messages. They are never uploaded
and are excluded from backup exports. See [PRIVACY.md](PRIVACY.md).

## Operational log

Alongside the usage log, the app and the command line write a content-free
operational record to `~/Library/Logs/ClipboardArchive/operational.ndjson` —
beside the launch agent's own logs, so Console shows them together. When
`CLIPBOARD_ARCHIVE_APPLICATION_SUPPORT_ROOT` is set, the log follows it to
`<that root>/Logs/` instead, so an isolated run never writes into the real
log.

Codes are `app_start`, `app_stop`, `heartbeat`, `second_instance_refused`,
`settings_fallback`, `settings_last_good_used`, `capture_failed`,
`capture_recovered`, `archive_append_failed`, `archive_tail_repaired`,
`index_missing_detected`, `index_corrupt_detected`, `index_upsert_failed`,
`index_rebuild_started`, `index_rebuild_finished`, `index_rebuild_failed`,
`retention_pruned`, `expiry_swept`, `pointer_published`,
`pointer_publish_failed`, and `cli_command`.

`heartbeat` is the reason the log exists. Every 30 minutes (the first beat a
minute after launch) the app records how many polls it ran and how many clips
it stored since the previous beat, its resident memory, and how long ago it
last captured. A launch that silently stopped working leaves no heartbeat —
the one failure no event-present record can show.

Every row carries the same fields, with zero or an empty string where a field
does not apply: `schema`, `timestamp` (UTC ISO 8601 with milliseconds), `pid`,
`version` (numeric components), `build`, `level` (`info`, `warn`, `error`),
`component` (`app`, `capture`, `archive`, `index`, `settings`, `retention`,
`launch`, `cli`), `code`, `errno`, `count`, `durationMs`, `bytes`, `polls`,
`captures`, `rssBytes`, and `verb` (a CLI verb name, or `unknown`). On a
`cli_command` row, `count` is the command's exit code. Every one
of those fields is a number or a value from a closed set: the API accepts no
free-form string, no error object and no path, so clipboard text, file names
and error messages cannot enter a row.

Each file is capped at 2 MiB, with five files total (`operational.ndjson` plus
`operational.1.ndjson` through `operational.4.ndjson`). The directory is
`0700`, files are `0600`, and writing is best effort — a log that cannot be
written never interrupts a capture or a launch. Read it with
`clipboard-archive logs` (`--tail N`, `--errors`, `--since`, `--json`).

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
