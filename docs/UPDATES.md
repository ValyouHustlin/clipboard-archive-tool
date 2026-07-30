# Updates

Clipboard Archive updates are explicit user-run installs. The installed app
does not check the internet for updates.

## One-Command GitHub Update

On the target Mac, run:

```bash
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/ValyouHustlin/clipboard-archive-tool/main/scripts/install-latest-github-release.sh)"
```

This downloads the latest GitHub Release, verifies `SHA256SUMS`, installs the
app and CLI, and reloads the login item.

Review the remote script before using this convenience form. The checksum file
is downloaded inside the same release artifact, so it detects damaged or
mismatched files but does not prove publisher identity.

To install a specific version:

```bash
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/ValyouHustlin/clipboard-archive-tool/main/scripts/install-latest-github-release.sh)" -- ValyouHustlin/clipboard-archive-tool v0.2.0
```

Verify afterward:

```bash
~/.local/bin/clipboard-archive health
```

## File Handoff Update

Build or download a newer release folder, copy it to that Mac, and run:

```bash
./install.sh
```

The installer replaces:

```text
~/Applications/ClipboardArchive.app
~/.local/bin/clipboard-archive
```

It preserves:

```text
~/Library/Application Support/ClipboardArchive/Archive/clipboard-history
~/Library/Application Support/ClipboardArchive/Indexes/clipboard-search.sqlite
~/Library/Application Support/ClipboardArchive/settings.json
```

The installer stages the app and saves the existing LaunchAgent before
stopping the running instance. If the replacement does not remain running, it
restores the previous app and LaunchAgent. The CLI is replaced only after the
new app passes that check.

## GitHub Recommendation

GitHub is useful as a source/release distribution point:

- Keep source history and issues in one place.
- Attach versioned `.zip` and `.tar.gz` release artifacts.
- Let other Macs download a release manually when you choose.

For a CLI-driven GitHub update, use a standalone human-run updater script, not
app-side update checks. See [GITHUB.md](GITHUB.md).

Do not add in-app auto-update checks unless the privacy model is revisited. The
current security stance is that the app itself has no network behavior.

Do not treat an ad hoc signature plus bundled checksums as a public release
trust chain. Developer ID signing, hardened runtime, notarization, and a
second-Mac Gatekeeper test are required before a paid or public beta.
