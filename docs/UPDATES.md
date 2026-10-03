# Updates

From 0.4.0, a copy of Clipboard Archive can update itself. Whether it does
depends on how that copy was built:

| Built with | What happens |
|---|---|
| `scripts/release.sh` (no `--feed-url`) | Never checks. Update by hand, as before. |
| `scripts/release.sh --feed-url URL` | A separate updater checks that feed once a day after you allow it, and when you choose **Check for Updates…**. |
| `scripts/package-release.sh` folder + `install.sh` | No updater. Update by hand, as before. |

## Two processes, one rule

The app that reads your clipboard makes no network request. It does not link
an updater, a network framework or a web view, and
`scripts/check-local-only.sh` fails the build if it ever does.

Updates are done by a second, small app inside the first one:

```text
Clipboard Archive.app/Contents/Helpers/Clipboard Archive Updater.app
```

It runs [Sparkle 2](https://sparkle-project.org). It does not link the
clipboard code, and its sources may not touch the pasteboard, the archive or
the index; the same check enforces that from the package graph and the shipped
binary. The app starts it at launch, and asks it to check through a local
notification when you choose **Check for Updates…**. It quits when the app
quits.

## What the updater sends

- An HTTPS `GET` for the appcast (the feed), and one for the disk image when
  there is a newer build.
- Sparkle's user agent: the app name, the app version, the Sparkle version.
- Nothing else: no system profile (it is off in the build and refused by the
  helper if it is ever turned on), no clipboard data, no account, no
  identifier.

Whoever hosts the feed sees the requesting IP address and that user agent,
like any download. Where the feed is hosted is a separate decision; see
"Hosting the feed" below.

## What the updater checks before installing

- The feed itself is signed (`SURequireSignedFeed`). A feed edited after
  signing is refused.
- The disk image carries an Ed25519 signature that must match the public key
  built into the installed copy. A changed byte is refused before anything is
  unpacked (`SUVerifyUpdateBeforeExtraction`).
- The feed must be HTTPS. The only exception is plain HTTP to `127.0.0.1` or
  `localhost`, which exists so the update path can be tested on one Mac.
- A downgrade is refused.
- None of this lapses: the build pins the library's grace period for a badly
  signed feed to zero, and the helper ignores any feed URL set in user
  defaults.
- Once copies are Developer ID signed, a disk image signed by the same Apple
  team is accepted even if its Ed25519 signature fails (the library's
  key-rotation path); see SECURITY.md.

Both refusals are exercised by `scripts/test-update-e2e.sh`.

## Check from a terminal

```bash
"/Applications/Clipboard Archive.app/Contents/Helpers/Clipboard Archive Updater.app/Contents/MacOS/ClipboardArchiveUpdater" --unattended --verbose
```

`--unattended` checks now and installs a newer build without asking. If the
app is running, the installer asks it to quit, replaces it and starts it
again. Exit codes follow the command line's numbering:

| Exit | Meaning |
|---|---|
| 0 | A newer build was installed. |
| 5 | Already up to date. |
| 3 | This copy has no feed or no key, so it never checks. |
| 4 | Refused: a signature, the feed signature, a downgrade or an insecure feed. |
| 1 | Failed for another reason (no network, no permission to write). |
| 2 | Usage mistake. |

There is no option to point the helper at another feed; the feed is the one
the copy was built with.

## The update signing key

One Ed25519 key pair signs every update. The public half is built into every
copy; the private half signs releases and must never be lost or shared,
because a copy can only accept updates signed by the key it was built with.

Create it once, on the Mac that makes releases:

```bash
./scripts/release.sh --fetch-sparkle-tools
.build/sparkle-tools/2.10.0/bin/generate_keys --account clipboard-archive
```

(Done 2026-10-03; the public key is in `release/update-signing-public-key.txt`.)

`generate_keys` stores the private key in the login keychain and prints the
public key. Save the public key, alone on one line, as
`release/update-signing-public-key.txt`. Export a backup of the private key
with `generate_keys --account clipboard-archive -x <file>` and keep it in the password manager, not in
this repository. (`--fetch-sparkle-tools` downloads Sparkle's
tools, pinned by version and checksum, into `.build/sparkle-tools/2.10.0`.)

## Hosting the feed

A release with a feed is two files to publish: the disk image and
`appcast.xml`. `release.sh` writes both but publishes nothing. Pass the feed
URL and the place the image will live:

```bash
./scripts/release.sh \
  --feed-url https://example.org/clipboard-archive/appcast.xml \
  --download-url-prefix https://example.org/clipboard-archive \
  --appcast path/to/the/currently/published/appcast.xml
```

`--appcast` adds the new build to the feed that is already published, so
older builds keep their entries. The appcast is signed after it is written;
edit it by hand and every copy will refuse it.

## Test the update path

```bash
./scripts/test-update-e2e.sh
```

It builds two numbered releases from a clean checkout with a throwaway key
and a test bundle identifier (`app.clipboardarchive.e2etest`), serves them on
`127.0.0.1` only, installs the older one by copying it out of its disk image,
lets that copy's own updater install the newer one, and then checks that a
tampered disk image and a tampered feed are both refused. It never launches
the app, never reads the clipboard and leaves no key in the keychain.

## Updating without the updater

The folder release still works:

```bash
./install.sh
```

The installer replaces `~/Applications/ClipboardArchive.app` and
`~/.local/bin/clipboard-archive`, keeps the archive, the index and the
settings, and puts the previous app and LaunchAgent back if the new app does
not stay running.

The GitHub Terminal helper also still works; review it before running it:

```bash
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/ValyouHustlin/clipboard-archive-tool/main/scripts/install-latest-github-release.sh)"
```

An ad hoc signature plus bundled checksums is not a public trust chain.
Developer ID signing, hardened runtime, notarization and a second-Mac
Gatekeeper test are required before a public release; see
[DISTRIBUTION.md](DISTRIBUTION.md).
