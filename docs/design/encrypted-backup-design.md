# Encrypted Backup/Export + Restore/Import — Implementation Design

Status: approved by lead 2026-07-30. Implements contracts 4/6/10 (feature
matrix row 11). Everything user-initiated; nothing automatic. No new deps
(`import CommonCrypto` is a platform system module); check-local-only.sh
unchanged — new files must contain no URL-shaped strings, even in comments.

## Cryptography (contract 10 clarification recorded in contracts doc)

- Passphrase → 32-byte master secret via CommonCrypto
  `CCKeyDerivationPBKDF(kCCPBKDF2, PRF=HMAC-SHA256)`. Salt: 16 random
  bytes/export. Iterations: `max(600_000, CCCalibratePBKDF(..., 250ms))`,
  stored in header; import rejects <100_000 (tamper) or >10_000_000 (DoS).
- CryptoKit `HKDF<SHA256>` expands the master secret into two
  domain-separated 256-bit keys (manifest key, payload key; info strings
  `app.clipboardarchive.backup.v1.manifest|payload`).
- AES-256-GCM combined boxes throughout. Nothing hand-rolled; PBKDF2 is the
  platform's vetted passphrase KDF (no scrypt/Argon2 without third-party
  deps); HKDF alone is not a password KDF.

## Container `*.clipbak` v1

```
"CLIPBAK1" (8) | formatVersion UInt32 LE = 1 | kdfHeaderLen UInt32 LE |
kdfHeader JSON (plaintext: backupID, createdAt, kdf, iterations, salt,
cipher, subkeyDerivation) | manifestBoxLen UInt64 LE | manifestBox
(AES-GCM, key=manifestKey, AAD=exact kdfHeader bytes) | per entry, per
4 MiB chunk: chunkBoxLen UInt32 LE + chunkBox (key=payloadKey,
AAD="CLIPBAK1"‖backupID(16)‖entryIndex BE‖chunkIndex BE) | EOF (trailing
bytes = hard error)
```

- Manifest (the only thing preview decrypts): version, backupID, createdAt,
  appVersion, schema/format versions, includesSettings, counts (stored/
  blocked/tombstone/ledger/bodies/annotations), dateRange, chunkSize,
  totalPlaintextBytes, entries[{path, kind, bytes, sha256, chunkCount}].
  Manifest authenticates the COMPLETE file set — drop/truncate/reorder/
  cross-backup splice all detected. Preview requires the passphrase
  (counts/dates are themselves sensitive — correct).
- Wrong passphrase and tamper are indistinguishable (GCM manifest auth):
  error says exactly that. Nothing written before manifest authenticates.
- Export = two passes (walk+hash builds manifest, then stream+seal);
  memory bounded ~1 chunk. Counts computed by the same enumeration code
  that selects files (preview parity).

## Contents

Included (allowlist): raw/ (all NDJSON lines as-is + large-items bodies),
deletion-ledger/, annotations/ (if present), manifests/ (historical, not
rebuildable), archive-format.json; settings.json optional (default OFF —
bundle ids are a fingerprint) under reserved path `meta/settings.json`.
Excluded with reasons: derived SQLite index (rebuildable; could resurrect
suppressed rows), lock file, staging dirs, hidden files. Non-allowlisted
regular files are reported by name ("not included") — layout drift fails
loudly. Enumeration: regular files only, no symlinks, every path through
containedURL.

## Merge-import semantics (id = event key; contentHash = annotation key)

- New id, not in local ledger → import into UTC day file. Existing id →
  skip. **Id in LOCAL ledger → content NOT written** ("skipped (deleted
  here)") — local deletion is authoritative, restore never resurrects.
- Backup ledger records → union (deletions never undone); a locally-live
  id newly suppressed is called out separately in the preview.
- Backup tombstone line absent locally → import as-is (no content).
- Blocked lines → idempotent append (skip byte-identical).
- Body path exists locally: hash equal → skip; hashes differ → HARD ERROR,
  whole import aborts pre-write (corruption signal).
- Annotations: pinned=OR (earlier pinnedAt), tags=union, snippet=OR,
  title/sensitivity=local wins, expiry=earlier (privacy-conservative).
  Collections: union by id (local name/order wins, unseen members
  appended); same name different id → keep both, imported renamed
  "<Name> (imported)". Zero-live-occurrence annotations import anyway.
- Restore-without-merge requires empty archive (no event files, no
  ledger); no "replace" mode is built (compose prune/redact first).
- Dry-run and execute share the same planning code (parity).

## Atomicity

Export: `.partial-<uuid>` created 0600-at-creation → stream → fsync →
atomic rename. Import phases: A authenticate+stage into hidden
`.backup-staging-<uuid>/` (0700; every entry path validated pre-create;
per-chunk tag+AAD+sha256+framing verified) — any failure deletes staging,
archive untouched. B plan (snapshot local ids/ledger/annotations →
matrix → preview; dry-run stops here). C commit in order: journal →
pre-images → LEDGER first (fail-closed: crash after = over-suppression,
never resurrection) → bodies (additive) → event day files (atomic
replace each) → annotations → format marker → index full rebuild (failure
= "run repair-index", no data rollback) → delete staging. Rollback on
error in 3–7: reverse order from pre-images, byte-identical tree. Stale
staging with journal detected at next backup entry and rolled back first.
Ledger cache invalidated after ledger merge.

## Surfaces

CLI `backup create <file> [--include-settings] [--passphrase-stdin]`,
`backup inspect <file> [--json]`, `backup restore <file> [--merge]
[--dry-run] [--apply-settings] [--json]`. Passphrase: TTY
`readpassphrase(3)` (create prompts twice, ≥8 chars); `--passphrase-stdin`
for tests. NEVER argv/env/logs; best-effort zeroization documented.
UI: "Back Up Archive…"/"Restore from Backup…" buttons on the Local Storage
card + Maintenance menu items; new ClipboardBackupUIController (save/open
panels, secure-field sheets, decrypted-manifest preview sheet with full
planned-action counts, off-main crypto with determinate progress).
Imported settings only through the tolerant decoder + settings store.
Post-import fires the archive-mutation hook (picker cache dirty).

## Files

New: Core/ClipboardBackup.swift (format, KDF, exporter, inspector, typed
errors — no content in error strings), Core/ClipboardBackupImporter.swift
(staging, validation, merge planner, journaled commit, recovery),
MenuBar/ClipboardBackupUIController.swift,
Tests/ClipboardBackupTests.swift + ClipboardBackupMergeTests.swift,
scripts/backup-roundtrip-check.sh. Modified: CLI main.swift, settings
window, app main.swift, contracts doc (crypto line), matrix row 11.
No Package.swift change.

## Test plan

Round-trips (empty / mixed-every-fixture-type / ≥3-chunk multi-day,
byte-identical + 0600/0700); settings include/apply matrix; wrong
passphrase = zero writes; bit-flips in header/manifest/chunk/swapped
chunks; truncation ×3; trailing bytes; iteration bounds; future version
error. Merge matrix one test per row incl. deleted-here (content absent
on disk after), ledger-union suppression visible via ClipboardSuppression
+ absent from rebuilt index, divergent-hash abort unchanged-tree, blocked
idempotence, annotation/collection merges. Hostile entries (../x, /abs,
raw/../../x, symlink-shaped, evil/) rejected pre-write. Fault injection
at each commit step → byte-identical rollback; stale-staging recovery.
Memory watermark on large bodies (never Data(contentsOf:) whole bodies).
CLI round-trip script + dry-run==execute parity + --json decode.

## Top risks

| Risk | Mitigation |
|---|---|
| SIGKILL mid-commit | ledger-first ordering (fail-closed), pre-image journal, next-entry recovery; orphan bodies harmless |
| Passphrase in Swift memory | best-effort zeroization; audit error paths for interpolation |
| Annotations landing order | merge isolated in one function w/ file-copy fallback; re-run tests when second lands |
| Hostile header DoS / size bombs | iteration caps; declared sizes bounded before allocation |
| Concurrent capture during import | in-process UI import; just-in-time per-file merge before each replace |
