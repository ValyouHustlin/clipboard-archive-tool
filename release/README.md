# Release inputs

`update-signing-public-key.txt` holds the Ed25519 public key that every
update-capable copy is built with, base64 on one line. It is public by
design. `scripts/release.sh --feed-url ...` reads it and refuses without it.

It does not exist yet: the key pair is created once by the release owner
(see docs/UPDATES.md, "The update signing key"). The private half lives in
the release Mac's login keychain with one offline backup, never here.
