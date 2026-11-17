# Next Session Handoff

Updated: 2026-11-17, after a full read of the repository.

## Where things stand

- The copy in daily use is 0.4.3 build 13 (2026-11-17), ad hoc signed, at
  `/Applications/Clipboard Archive.app`, installed with the published release
  folder's `install.sh` over a disk-image install of 0.4.1. That copy has no
  update helper inside it (only the disk image does), and no update feed
  exists, so "Check for Updates…" says updates are not available. The
  command-line tool there is 0.4.3 too.
- The public GitHub repository is current with `main`, and 0.4.3 is the
  published "latest" release. 0.4.2 fixed the installer; 0.4.3 lets a newer
  copy take over from an older one and repair the login item.
- The 0.4.3 install on the daily-use Mac was checked against its real data:
  every earlier history file byte-identical, settings unchanged, the data
  location carried over, one copy of the app, `verify` clean.
- 0.4.1 was checked three ways before it replaced 0.3.0 build 9: the test
  suite, a sandboxed scratch run of the release binary with a moved clock
  (a timed pause ends; the 0.3.0 binary stays paused in the same run), and one
  click-through on the installed copy (private mode started from the menu
  survives Save in an open Settings window).

## Checks

`swift test` is the gate, run on a Mac. Nothing runs it automatically: the
workflow file needs a macOS runner and no runner is set up for it. Before a
release, also run by hand: `test-install-locations.sh` and
`test-upgrade-keeps-data.sh` (neither needs a release folder; both stay in a
scratch home and never look at the real `/Applications`), then
`validate-release.sh`, `check-local-only.sh`, `test-release.sh`,
`test-install-rollback.sh` and `test-update-e2e.sh`.

## What an update must keep

History, settings, pins and tags, and the data location. The installer never
writes inside the archive or the settings file; it carries the data location
over from the login item it replaces. The app keeps every older settings key
and reads archives and search indexes back to 0.1.2. A newer copy dragged in
from the disk image beside an older folder install takes over from it and
points the login item at itself (`ClipboardInstallRepair`, carried out in
`InstallRepairRunner`); it leaves the older copy on disk. Nothing tests a
downgrade.

The takeover and login-item repair are covered by unit tests on the decisions.
The end-to-end check is by hand: an isolated run of an older app bundle, then
the new one on the same scratch root with `CLIPBOARD_ARCHIVE_LAUNCH_AGENT_PLIST`
naming a scratch login item. Run it with the four path variables and without
`run-isolated-app.py`: that sandbox blocks the quit request one app sends the
other, so the takeover falls back to a signal there.

## Open decisions

1. Where the update feed is hosted. Until that is decided no copy can update
   itself, and `docs/UPDATES.md` describes a path nobody can use yet.
2. Developer ID signing and notarization, for installs that open with a
   double-click.
3. LICENSE is MIT with copyright "Clipboard Archive contributors". Whether to
   keep that line and that license is still unanswered.
4. Where CI runs: a Mac runner, or the release scripts by hand as today.

## Known gaps, not yet fixed

- The deletion ledger is appended without the archive write lock and without
  the day files' torn-row repair. A crash mid-append, or the app and the
  command-line tool appending at once, can cost a ledger row; a later merge
  restore would then bring that deleted clip's body back.
- A restore into an empty archive copies the backup's day files over whatever
  is there. A clip captured into a new day file in the moments before that
  copy is replaced by the backup's file for the same day.
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
