# GitHub Release Flow

Clipboard Archive can use GitHub for source history and release file hosting
without adding any network behavior to the installed app.

## Boundary

- The installed app stays local-only.
- The LaunchAgent stays local-only.
- The installed CLI stays local-only.
- Release archives do not include private workstation archives, indexes,
  reports, or local helper paths.
- GitHub is only used by a human-run Terminal command when you choose to
  download an update.

## Release Process

From the development Mac:

```bash
CLIPBOARD_ARCHIVE_VERSION=0.1.1 CLIPBOARD_ARCHIVE_BUILD=2 ./scripts/package-release.sh
./scripts/validate-release.sh releases/ClipboardArchive-0.1.1-macos-arm64
```

Create a GitHub Release tag such as:

```text
v0.1.1
```

Attach these files:

```text
releases/ClipboardArchive-0.1.1-macos-arm64.zip
releases/ClipboardArchive-0.1.1-macos-arm64.tar.gz
```

## Update Another Mac

Manual file handoff still works:

```bash
unzip ClipboardArchive-0.1.1-macos-arm64.zip
cd ClipboardArchive-0.1.1-macos-arm64
./install.sh
```

GitHub-hosted update:

```bash
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/ValyouHustlin/clipboard-archive-tool/main/scripts/install-latest-github-release.sh)"
```

This is the recommended command for another Mac. It downloads the latest
release zip, verifies `SHA256SUMS`, installs the app and CLI, preserves local
history/settings, and reloads the login item.

Pinned version:

```bash
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/ValyouHustlin/clipboard-archive-tool/main/scripts/install-latest-github-release.sh)" -- ValyouHustlin/clipboard-archive-tool v0.1.1
```

The updater downloads the release zip, verifies `SHA256SUMS`, runs the bundled
`install.sh`, and preserves local archive data/settings.

## Do Not Add

Do not add app-side auto-update checks, telemetry, analytics, or release polling
without revisiting the privacy model. The current design intentionally keeps
network activity outside the app runtime.
