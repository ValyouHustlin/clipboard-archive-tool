# Next Session Handoff

Updated: 2026-11-17, after a full read of the repository.

## Where things stand

- The copy in daily use is 0.4.1 build 11 (2026-11-17), ad hoc signed, at
  `/Applications/Clipboard Archive.app`, installed from the disk image that
  `scripts/release.sh` builds. It has no update feed, so its update helper
  stays dormant. The command-line tool was updated to the same version.
- The public GitHub repository stops at 0.2.0. Everything after it (the 0.3.0
  hardening, the 0.4.0 release path and 0.4.1) exists only in the private
  mirror.
- 0.4.1 was checked three ways before it replaced 0.3.0 build 9: the test
  suite, a sandboxed scratch run of the release binary with a moved clock
  (a timed pause ends; the 0.3.0 binary stays paused in the same run), and one
  click-through on the installed copy (private mode started from the menu
  survives Save in an open Settings window).

## Checks

`swift test` is the gate, run on a Mac. Nothing runs it automatically: the
workflow file needs a macOS runner and no runner is set up for it. The release
scripts (`validate-release.sh`, `check-local-only.sh`, `test-release.sh`,
`test-install-rollback.sh`, `test-update-e2e.sh`) are run by hand before a
release.

## Open decisions

1. Publish: push to GitHub and cut a 0.4.0 release, or keep the repository
   private from here on. Several docs describe an install path (the
   `curl` installer, the pinned `v0.2.0` example) that only works once a
   matching GitHub Release exists.
2. Where the update feed is hosted. Until that is decided no copy can update
   itself, and `docs/UPDATES.md` describes a path nobody can use yet.
3. One install location. The disk image installs
   `/Applications/Clipboard Archive.app`; the release folder's `install.sh`
   installs `~/Applications/ClipboardArchive.app` under the same bundle id and
   rewrites the shared LaunchAgent. Running `install.sh` on a Mac that has the
   disk image copy leaves two apps and points login at the second.
4. Developer ID signing and notarization, for installs that open with a
   double-click.
5. LICENSE is MIT with copyright "Clipboard Archive contributors". Whether to
   keep that line and that license is still unanswered.
6. Where CI runs: a Mac runner, or the release scripts by hand as today.

## Known gaps, not yet fixed

- Archive rewrites (bulk delete, expiry, restore, retention) read a day file
  and replace it with no lock against the capture appender. A capture landing
  in that window is lost. Needs one write lock shared by the writer and every
  rewrite.
- In a "keep latest N" mode every capture runs a full archive scan on the
  main thread once N is reached, and the cost grows with history.
- The Settings window still saves its own copy of retention and app rules. A
  retention change made from the menu while it is open is overwritten by Save.
- The secret detector blocks some ordinary text (`sort_key=relevance1`) and
  misses some credentials (`github_pat_`, AWS `ASIA` keys, long hex tokens).
- Manual checks that need a real session: global hotkey registration and
  conflicts, the shortcut recorder, direct paste with Accessibility trust,
  launch at login from an installed app.
- Old builds that redact a rich clip leave its body file behind; `health`
  counts these as `orphanedRichBodyFiles`.

## Ground rules that still apply

Do not read clipboard contents from the real archive or indexes for
development or tests. All development and testing uses isolated `/tmp` roots
through the four `CLIPBOARD_ARCHIVE_*` path variables
([ISOLATED_TESTING.md](ISOLATED_TESTING.md)) and synthetic fixtures. Do not
stop or replace the live app, install login items, or start live capture
without explicit approval. `check-local-only.sh` is the network-abstinence
gate; keep it green.
