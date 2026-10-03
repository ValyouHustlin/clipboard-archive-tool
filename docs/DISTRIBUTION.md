# Distribution

There are two release formats.

| Format | Made by | For |
|---|---|---|
| Disk image (`.dmg`) | `scripts/release.sh` | People: drag the app to Applications. Can update itself. |
| Release folder (`.zip`, `.tar.gz`) | `scripts/package-release.sh` | Scripts and the CLI: `install.sh` installs the app, the CLI and a LaunchAgent. |

The version and build number come from the newest CHANGELOG entry of the form
`## <version> build <n> - <date>` unless you pass them. Release notes come
from that same entry, so a release without one refuses to build.

## Disk image release

```bash
./scripts/release.sh
```

Output, in `releases/<version>-build<n>/`:

```text
ClipboardArchive-<version>-build<n>.dmg          the app and an Applications shortcut
ClipboardArchive-<version>-build<n>.dmg.sha256   its SHA-256
release-notes.md, release-notes.html             from CHANGELOG.md
release.json                                     version, build, commit, signing, checksum
appcast.xml                                      only with --feed-url and --download-url-prefix
```

What it does, in order, stopping at the first problem:

1. **Preflight.** A CHANGELOG entry for the version; a clean working tree,
   untracked files included (`--allow-dirty` overrides and the release says
   DIRTY); for `--sign developer-id` a Developer ID Application certificate
   in the keychain; for `--notarize` a notary profile that `notarytool
   history` accepts; with a feed, HTTPS URLs and a signing key whose public
   half matches `release/update-signing-public-key.txt`. Refusals exit 3
   before anything is built.
2. **Build** the app and the update helper in release mode.
3. **Assemble** the helper inside the app with Sparkle's framework (its XPC
   services removed; the app is not sandboxed).
4. **Configure updates** in the app's `Info.plist`: system profiling off
   always; feed, public key, signed-feed and verify-before-extraction only
   with `--feed-url`.
5. **Sign** inside out: Sparkle's `Autoupdate` and `Updater.app`, the
   framework, the helper, the app. Then `codesign --verify --deep --strict`.
6. **Check the boundary** (`check-local-only.sh --app`) and **scan** the
   executables, the property lists and the notes for home directories, email
   addresses, tailnet hosts and private addresses.
7. **Disk image**, checksum, and with a feed the signed appcast.

Try it without building:

```bash
./scripts/release.sh --preflight-only
./scripts/release.sh --sign developer-id --notarize --notary-profile NAME --preflight-only
```

## Signing

Today's releases are **ad hoc** signed. That binds the bundle's contents to
the signature, but it has no Apple Team ID: Gatekeeper on another Mac will
not open a downloaded copy without a right-click override, and nothing proves
who built it.

The Developer ID path is built and waits for a certificate:

```bash
./scripts/release.sh --sign developer-id --notarize --notary-profile clipboard-archive
```

`--sign developer-id` signs every piece with the hardened runtime and a
secure timestamp, and signs the disk image. `--notarize` submits the app,
staples the ticket to it, then submits and staples the disk image.

One-time setup on the release Mac, once the Apple Developer account can issue
certificates:

1. Create a **Developer ID Application** certificate and install it in the
   login keychain. `security find-identity -v -p codesigning` should list it.
2. Save notary credentials under a profile name:
   `xcrun notarytool store-credentials clipboard-archive` (an app-specific
   password or an App Store Connect API key).

Until then the flag refuses before building:

```text
release refused: --sign developer-id needs a 'Developer ID Application' certificate, and this keychain has none.
```

Updates keep working across the change from ad hoc to Developer ID: the
updater trusts the update signing key, not the code signature, so a copy
signed either way accepts the other as long as the key is the same.

## Release folder

```bash
./scripts/package-release.sh
./scripts/validate-release.sh releases/ClipboardArchive-<version>-macos-<arch>
```

Packaging builds into `.build/clipboard-archive-package/ClipboardArchive.app`;
it does not replace `dist/ClipboardArchive.app` or a running installation.
`SHA256SUMS` detects damaged or mismatched files inside the folder; because it
ships beside the files it does not establish who published them.

## Update model

See [UPDATES.md](UPDATES.md). In short: the app that reads the clipboard
never connects to anything; a separate helper, present only in disk image
releases built with a feed, checks for and installs signed updates.
Clipboard contents, archives, indexes, settings and health data stay on the
Mac.
