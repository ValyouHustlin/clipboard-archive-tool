# Next Session Handoff

Updated: 2026-07-30 (evening), end of the complete feature expansion lane.

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
- The LIVE installed app now RUNS the 0.2.0 build (Aaron-executed dist
  swap, twice on 2026-07-30: the expansion itself, then the What's New
  onboarding addition — binary f37879f9, PID verified stable; ops-journal
  has both records). Rollback bundle:
  `dist/ClipboardArchive.app.pre-0.2.0-backup`. Any future live swap must
  be run by Aaron himself (`!` command) — the auto-mode guardrail blocks
  agent-issued stops/replacements of the live app and any CLI pointed at
  the real archive paths.
- A "What's New" window now shows once per version (tolerant
  `lastSeenAppVersion` settings key) after upgrades and as an optional
  first-run second step.

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
5. Open question for Aaron: LICENSE is MIT with copyright "Clipboard
   Archive contributors" (original to the 2026-05-15 public release) — he
   asked how it got MIT-licensed and has not yet said whether to change
   the copyright line/license.
6. Saint NAS mirror has two stale merged branches (slice3-archive-search,
   slice5-bulk-privacy) and an unsynced main; cleanup needs Aaron-run:
   `git push saint main && git push saint --delete slice3-archive-search slice5-bulk-privacy`.
7. `dist/AIHubClipboard.app` is an old pre-rename bundle predating this
   lane — left in place, flagged for Aaron.

## Ground rules that still apply

Never read the real archive under `Development/AI-Hub-Archive` or indexes
under `Development/AI/data`. All dev/testing uses isolated `/tmp` roots via
`CLIPBOARD_ARCHIVE_*` env vars and synthetic fixtures. Do not stop or
replace the live app, install login items, or start live capture without
explicit approval. `check-local-only.sh` is the network-abstinence gate —
keep it green.
