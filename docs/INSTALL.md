# Install And Update

Clipboard Archive ships as a folder containing:

```text
ClipboardArchive.app
bin/clipboard-archive
install.sh
uninstall.sh
manifest.json
SHA256SUMS
docs/
```

## Install

```bash
./install.sh
```

The default install is per-user:

```text
~/Applications/ClipboardArchive.app
~/.local/bin/clipboard-archive
~/Library/LaunchAgents/app.clipboardarchive.plist
~/Library/Application Support/ClipboardArchive/Archive/clipboard-history
~/Library/Application Support/ClipboardArchive/Indexes/clipboard-search.sqlite
```

## Custom Data Location

```bash
CLIPBOARD_ARCHIVE_ARCHIVE_ROOT="$HOME/Documents/Clipboard Archive/Archive" \
CLIPBOARD_ARCHIVE_INDEX_PATH="$HOME/Documents/Clipboard Archive/clipboard-search.sqlite" \
./install.sh
```

## Update

Install a newer release folder the same way:

```bash
./install.sh
```

The installer stops the running app, replaces the app bundle, updates the CLI,
rewrites the LaunchAgent, and starts the new app. Existing archive data remains
in place.

Updates are file handoffs. The installed app does not check the internet for
new versions.

## CLI

The installer writes:

```text
~/.local/bin/clipboard-archive
```

Use it for local checks:

```bash
clipboard-archive health
clipboard-archive search "example" --limit 10
clipboard-archive prune --until 2026-01-01 --dry-run
clipboard-archive prune --until 2026-01-01
clipboard-archive repair-index
clipboard-archive write-manifest
```

## Settings

Open the menu bar icon and choose `Settings...`.

Current controls:

- Capture on/off.
- Storage mode: remember 10 items, remember 50 items, or full archive.
- Number of items shown in the app.
- Poll interval.
- Excluded app bundle identifiers.
- Archive/settings path visibility.

Excluded apps use bundle identifiers, not display names from the Applications
folder. Examples:

```text
com.apple.Safari
com.brave.Browser
com.1password.1password
```

## Uninstall

```bash
./uninstall.sh
```

Uninstall removes the app and LaunchAgent but leaves archive data in place.
