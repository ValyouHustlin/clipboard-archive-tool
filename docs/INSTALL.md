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

The installer validates the release folder's bundled checksums before stopping
an existing app. It stages the new bundle, verifies that it remains running,
and restores the previous app and LaunchAgent definition on failure. Checksums
detect corruption or mismatched files, not publisher identity; public builds
still require Developer ID signing and notarization.

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
in place. If the new app does not remain running, the prior app and LaunchAgent
are restored.

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

## Start At Login

There are two separate mechanisms that can start Clipboard Archive at login.
Use ONE of them, never both — enabling both launches the app twice (the
second instance exits against the single-instance lock, but the race is
noisy and pointless).

1. LaunchAgent (installer-managed). `./install.sh` writes
   `~/Library/LaunchAgents/app.clipboardarchive.plist` and loads it. This is
   the default for installed copies and what the updater preserves. Remove
   it with `./uninstall.sh` or:

   ```bash
   launchctl bootout "gui/$(id -u)" ~/Library/LaunchAgents/app.clipboardarchive.plist
   rm ~/Library/LaunchAgents/app.clipboardarchive.plist
   ```

2. macOS Login Items (in-app toggle). Settings › Startup & About has a
   "Start Clipboard Archive when you log in" checkbox backed by the system
   Login Items list (SMAppService, macOS 13+). It is off by default, is
   never enabled automatically, and reflects the real system state —
   including "waiting for approval" (finish in System Settings › General ›
   Login Items) and "unavailable" when the app is not in a normal app
   location. Manage or revoke it any time from System Settings.

If you used `install.sh`, keep the in-app toggle off, or remove the
LaunchAgent first if you prefer the Login Items mechanism.

## Settings

Open the menu bar icon and choose `Settings...`.

On a new profile, capture begins off. The first-run window explains plaintext
storage and filtering limits, then offers no capture, last 50 items
(recommended), or a full archive.

Current controls:

- Capture on/off, plus rich-format capture (images, files, rich text,
  colors, titled links).
- Storage mode: remember 10 items, remember 50 items, or full archive.
- History window (1/7/14/30 days) and number of items shown in the app.
- Poll interval.
- App privacy rules: Block, Store-don't-index, or Normal per bundle
  identifier (legacy exclusion lists still load).
- Quick picker global shortcut and optional direct paste.
- Launch at login (see above; off by default).
- Local storage details, Storage & Health dashboard, encrypted backup and
  restore.
- About: app version, archive format, event schema, and search index schema
  versions, plus the GitHub Releases page URL. Updates are manual; the app
  never checks the internet.

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
