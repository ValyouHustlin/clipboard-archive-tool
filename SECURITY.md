# Security Model

Clipboard Archive is a local-first clipboard history app. It is designed for a
single trusted macOS user account, not for hostile multi-user machines or
managed enterprise distribution without additional controls.

## What It Does Not Do

- It does not encrypt clipboard archive files at rest.
- It does not claim password-manager blocking is perfect.
- It does not notarize release builds until a Developer ID certificate
  exists; `scripts/release.sh --sign developer-id --notarize --notary-profile NAME`
  is the path, and it refuses while the certificate is missing.
- It does not protect copied content from malware, another process running as
  the same user, unlocked laptop access, Time Machine, APFS snapshots, or other
  backups that already captured the files.

## Plaintext Storage

Accepted clipboard items are stored in local plaintext NDJSON/body files under
the configured archive root. The derived SQLite FTS index is also plaintext.
App-created directories use owner-only mode `0700`; files use owner-only mode
`0600`.

This is intentional for the current version because the app's main job is local
searchability and durable machine-readable history. Treat the archive as
sensitive data. Anyone or anything with read access to your user account may be
able to read it.

CryptoKit hashes clipboard contents and encrypts the backups you create; the
archive itself is not encrypted at rest.
Processes running as the same macOS user can still read those files.

Archive-relative body paths are rejected if they are absolute, contain
traversal components, or escape through a symlink. Derived-index rebuilds are
created and checked at a temporary sibling path before atomic replacement.

## Sensitive Work

Use the pause control or turn off permanent archive tracking before copying
highly sensitive data. Password-manager and obvious-secret blocking reduce risk
but are best effort. Browser password fields and autofill contexts are not
reliably detectable through normal pasteboard polling.

The filter honors standard macOS concealed/transient pasteboard types and known
password-manager types before source-app and credential-pattern checks. Apps
that do not mark sensitive clipboard values still depend on the other
best-effort signals.

Prefer copying passwords from a password manager app that can be excluded by
bundle identifier rather than from arbitrary browser pages.

If you do not want an indefinite plaintext archive, set storage mode to
`Remember 10 Items` or `Remember 50 Items`. Those modes keep the app useful for
day-to-day clipboard recall while automatically pruning older stored content.

## Pruning

Manual delete/redact removes stored content for selected items while retaining
timeline metadata.

For periodic cleanup, use:

```bash
clipboard-archive prune --until 2026-01-01 --dry-run
clipboard-archive prune --until 2026-01-01
```

Pruning redacts matching archive content, removes large body files, records
deletion markers, and removes the matching rows from the local SQLite search
index. Pinned clips are kept unless you pass `--include-pinned`. It does not
erase external backups or snapshots that already captured the files.

## Signing

Default release builds are ad hoc signed after the app bundle is assembled, so
the app's `Info.plist` and resource seal are bound to the signature. Ad hoc
signing provides local code-signing structure but no Apple Team ID and no
notarization.

For wider distribution, use a Developer ID certificate, hardened runtime, and
Apple notarization:
`scripts/release.sh --sign developer-id --notarize --notary-profile NAME`
(see [docs/DISTRIBUTION.md](docs/DISTRIBUTION.md)).

## Updates

The app that reads the clipboard has no network code. Updates run in a
separate helper app (`Contents/Helpers/Clipboard Archive Updater.app`) that
has no clipboard code; `scripts/check-local-only.sh` enforces both halves.
The helper is a process of the same user, so this is a code boundary, not an
operating-system sandbox: it keeps network-facing parsing out of the process
that holds clipboard contents, and keeps clipboard access out of the process
that talks to the network.

An update is installed only when:

- the feed is HTTPS (plain HTTP is accepted only to 127.0.0.1 or localhost,
  for local tests),
- the feed carries a valid Ed25519 signature,
- the update file carries a valid Ed25519 signature from the key built into
  the installed copy, checked before it is unpacked, and
- it is not a downgrade.

The feed's signature never expires: the build sets
`SUSignedFeedFailureExpirationInterval` to 0, without which the updater
library would parse an unverified feed 20 days after its first bad
signature, and the helper refuses any copy built without it. The helper
also uses only the feed built into the app, never a `SUFeedURL` from user
defaults.

One documented exception, for key rotation: once the installed copy is
Developer ID signed, an update disk image that fails its Ed25519 check is
still accepted if it carries a valid Developer ID signature from the same
Apple team. That trusts the Apple signing identity instead of the update
key for the update file only; it does not apply to today's ad hoc copies.
The feed must still verify against the key built into the installed copy,
so a key rotation still needs the old private key to sign the feed that
announces it. Keep the backup.

The private update key is the root of that trust. Losing it means installed
copies can no longer be updated automatically; leaking it means someone else
can sign updates. Keep it in the login keychain of the release Mac with one
offline backup, never in this repository.

Bundled `SHA256SUMS` detect corruption or mismatched extracted files. Because
the checksum file ships beside the artifact, it does not authenticate the
publisher; Developer ID signing and notarization remain the public trust
boundary.

## Reporting Issues

Open a GitHub issue for security hardening ideas that do not include sensitive
clipboard contents, credentials, or private archive excerpts.

## Local diagnostics

Content-free usage records are stored under the archive's `usage/` directory
with owner-only permissions and a 5 MiB total NDJSON cap. They contain usage
timestamps, typed events/outcomes/scopes, numeric version/build, counts,
durations, and sizes. They contain no clip text, queries, IDs, hashes, source
apps, paths, or raw errors. See [PRIVACY.md](PRIVACY.md) for the exact schema.
Diagnostics are best effort, stay local, and are excluded from backup exports.
