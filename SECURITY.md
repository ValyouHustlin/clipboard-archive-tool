# Security Model

Clipboard Archive is a local-first clipboard history app. It is designed for a
single trusted macOS user account, not for hostile multi-user machines or
managed enterprise distribution without additional controls.

## What It Does Not Do

- It does not encrypt clipboard archive files at rest.
- It does not claim password-manager blocking is perfect.
- It does not notarize release builds unless you add an Apple Developer ID
  signing and notarization workflow.
- It does not protect copied content from malware, another process running as
  the same user, unlocked laptop access, Time Machine, APFS snapshots, or other
  backups that already captured the files.

## Plaintext Storage

Accepted clipboard items are stored in local plaintext NDJSON/body files under
the configured archive root. The derived SQLite FTS index is also plaintext.

This is intentional for the current version because the app's main job is local
searchability and durable machine-readable history. Treat the archive as
sensitive data. Anyone or anything with read access to your user account may be
able to read it.

CryptoKit is linked for hashing clipboard contents, not for archive encryption.

## Sensitive Work

Use the pause control or turn off permanent archive tracking before copying
highly sensitive data. Password-manager and obvious-secret blocking reduce risk
but are best effort. Browser password fields and autofill contexts are not
reliably detectable through normal pasteboard polling.

Prefer copying passwords from a password manager app that can be excluded by
bundle identifier rather than from arbitrary browser pages.

## Pruning

Manual delete/redact removes stored content for selected items while retaining
timeline metadata.

For periodic cleanup, use:

```bash
clipboard-archive prune --until 2026-01-01 --dry-run
clipboard-archive prune --until 2026-01-01
```

Pruning redacts matching archive content, removes large body files, records
deletion markers, and rebuilds the local SQLite search index. It does not erase
external backups or snapshots that already captured the files.

## Signing

Default release builds are ad hoc signed after the app bundle is assembled, so
the app's `Info.plist` and resource seal are bound to the signature. Ad hoc
signing provides local code-signing structure but no Apple Team ID and no
notarization.

For wider distribution, use a Developer ID certificate, hardened runtime, and
Apple notarization.

## Reporting Issues

Open a GitHub issue for security hardening ideas that do not include sensitive
clipboard contents, credentials, or private archive excerpts.
