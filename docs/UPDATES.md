# Updates

Clipboard Archive updates are file handoffs by default.

The installed app does not check the internet for updates. To update another
Mac, build or download a newer release folder, copy it to that Mac, and run:

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

## GitHub Recommendation

GitHub is useful as a source/release distribution point:

- Keep source history and issues in one place.
- Attach versioned `.zip` and `.tar.gz` release artifacts.
- Let other Macs download a release manually when you choose.

For a CLI-driven GitHub update, use a standalone human-run updater script, not
app-side update checks. See [GITHUB.md](GITHUB.md).

Do not add in-app auto-update checks unless the privacy model is revisited. The
current security stance is that the app itself has no network behavior.
