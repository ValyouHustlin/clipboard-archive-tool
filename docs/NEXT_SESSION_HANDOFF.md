# Next Session Handoff

Updated: 2026-09-15, local 0.3.0 build 7 release.

## Where things stand

The seven September hardening changes are integrated through `2e1df3d`: shared store resolution, operational heartbeats, crash recovery, capture during tracking modes, native SQLite calls, background history loading, and the expanded CLI contract. The release package is `releases/ClipboardArchive-0.3.0-macos-arm64`, with standalone CLI identity embedded in its executable and the generated command reference included.

The local release is authorized to replace the existing `dist/ClipboardArchive.app` and `~/.local/bin/clipboard-archive`, then restart the existing launch job. It preserves the launch plist and all capture, retention and privacy settings. The app's normal upgrade onboarding may advance `lastSeenAppVersion` to `0.3.0`.

The dated install receipt is the authority for installed version, PID, timestamps, rollback and checks; do not infer current runtime state from this document. Evidence: `/Users/legacy/Development/AI/reports/clipboard-archive/2026-09-15/hardening/evidence/release/RELEASE-RECEIPT.md`. The parent lane owns independent certification, live heartbeat observations and archive postflight.

### Release decisions and assumptions

- CLI identity is embedded at link time, with no runtime environment or neighboring-app fallback; unpackaged development binaries retain the development label.
- Package validation relocates the CLI alone and uses scratch roots for every command.
- App and CLI rollback copies are retained before the live process is stopped; no launch/login configuration is changed.
- Certification and long-running capture evidence remain separate from this release's build and install checks.

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

Do not read clipboard contents from the real archive or indexes for development or tests. All dev/testing uses isolated `/tmp` roots via
`CLIPBOARD_ARCHIVE_*` env vars and synthetic fixtures. Do not stop or
replace the live app, install login items, or start live capture without
explicit approval. `check-local-only.sh` is the network-abstinence gate —
keep it green.
