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
./scripts/validate-release.sh releases/ClipboardArchive-0.2.0-macos-arm64
```

Packaging builds into `.build/clipboard-archive-package/ClipboardArchive.app`;
it does not replace the repository's `dist/ClipboardArchive.app` or a running
installation.

Release builds are ad hoc signed after the `.app` bundle is assembled. This
binds the app's `Info.plist` and resource seal, but it is not Apple Developer
ID signing or notarization.

`SHA256SUMS` is validated by the release validator and installer. It detects
corruption or mismatched files inside an extracted release, but because it
ships beside the artifact it does not establish publisher identity.

## Versioning

```bash
CLIPBOARD_ARCHIVE_VERSION=0.2.0 CLIPBOARD_ARCHIVE_BUILD=2 ./scripts/package-release.sh
```

## Sharing To Another Mac

Copy the release folder, tarball, or zip to the target Mac. Then run:

```bash
./install.sh
```

Running `install.sh` again with a newer release updates the app in place.
The installer stages the replacement and retains the prior app/LaunchAgent
until the new executable has remained running.

See [UPDATES.md](UPDATES.md) and [GITHUB.md](GITHUB.md) for the recommended
GitHub/file-handoff update flow.

## Update Model

The update model is intentionally local. Copy a newer release folder, tarball,
or zip to the target Mac and run `install.sh`. The installed app does not check
the internet for updates and does not include an auto-updater.

Any future distribution channel must preserve this rule: clipboard contents,
archives, indexes, settings, and health data stay on the local Mac unless the
user explicitly copies files elsewhere outside the app.
