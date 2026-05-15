# Distribution

Build a shareable release from the repository root:

```bash
./scripts/package-release.sh
```

Outputs:

```text
releases/ClipboardArchive-<version>-macos-<arch>/
releases/ClipboardArchive-<version>-macos-<arch>.tar.gz
releases/ClipboardArchive-<version>-macos-<arch>.zip
```

The folder is the canonical handoff format. The tarball and zip are convenient
for copying to another Mac.

Validate a staged release before handoff:

```bash
./scripts/validate-release.sh releases/ClipboardArchive-0.1.0-macos-arm64
```

## Versioning

```bash
CLIPBOARD_ARCHIVE_VERSION=0.1.1 CLIPBOARD_ARCHIVE_BUILD=2 ./scripts/package-release.sh
```

## Sharing To Another Mac

Copy the release folder, tarball, or zip to the target Mac. Then run:

```bash
./install.sh
```

Running `install.sh` again with a newer release updates the app in place.

See [UPDATES.md](UPDATES.md) and [GITHUB.md](GITHUB.md) for the recommended
GitHub/file-handoff update flow.

## Update Model

The update model is intentionally local. Copy a newer release folder, tarball,
or zip to the target Mac and run `install.sh`. The installed app does not check
the internet for updates and does not include an auto-updater.

Any future distribution channel must preserve this rule: clipboard contents,
archives, indexes, settings, and health data stay on the local Mac unless the
user explicitly copies files elsewhere outside the app.
