# Release inputs

`update-signing-public-key.txt` holds the Ed25519 public key that every
update-capable copy is built with, base64 on one line. It is public by
design. `scripts/release.sh --feed-url ...` reads it and refuses without it.

Created 2026-10-03 with Sparkle's `generate_keys --account clipboard-archive`.
The private half lives in the release Mac's login keychain under that account
name, with one backup in the release Mac's secrets store, never here.
`release.sh` signs with that keychain account unless given `--ed-key-file`.
