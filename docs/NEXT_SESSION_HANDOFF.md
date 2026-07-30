# Next Session Handoff

Updated: 2026-07-30, end of the complete feature expansion lane.

## Where things stand

The 2026-07 feature expansion is COMPLETE at HEAD on `main`: all 12 approved
features are integrated, independently reviewed, and gated (see
`docs/feature-matrix.md` for per-feature receipts and the discovered-issues
log, and `docs/expansion-contracts.md` for the binding architecture
contracts). Version 0.2.0 is prepared: `CHANGELOG.md` has the full entry and
`releases/ClipboardArchive-0.2.0-macos-arm64` (+ tarball/zip/SHA256SUMS)
builds and validates.

- Gates at HEAD: full swift-testing suite, `clipboard-archive-checks`,
  `package-release.sh`, `validate-release.sh`, `check-local-only.sh`,
  `test-install-rollback.sh`, `backup-roundtrip-check.sh`, 50k scale
  benchmark — all green. GitHub CI runs the same ladder.
- The LIVE installed app still runs the PRE-expansion build. Replacing it
  requires fresh explicit approval from Aaron (AI Hub archive workflow +
  the install script). Nothing in this lane touched it.

## Outstanding (small, deliberate)

1. Manual QA that this lane could not automate (needs a real session):
   real global-hotkey registration + conflict surfacing, the interactive
   shortcut recorder, direct paste with Accessibility trust, SMAppService
   launch-at-login enable/approve flows from an installed .app.
2. Bulk-sheet PNG snapshots render text without control chrome
   (never-presented-sheet limitation) — behavior is receipt-proven.
3. Old-build redaction orphans rich bodies (forward-compat gap) — visible
   via `health` `orphanedRichBodyFiles`.
4. Open-source download gates from the production-readiness review still
   stand: Developer ID signing/notarization + a published GitHub Release
   are needed for one-click nontechnical installs.

## Ground rules that still apply

Never read the real archive under `Development/AI-Hub-Archive` or indexes
under `Development/AI/data`. All dev/testing uses isolated `/tmp` roots via
`CLIPBOARD_ARCHIVE_*` env vars and synthetic fixtures. Do not stop or
replace the live app, install login items, or start live capture without
explicit approval. `check-local-only.sh` is the network-abstinence gate —
keep it green.
