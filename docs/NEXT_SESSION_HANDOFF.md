# Next Session Handoff

Updated: 2026-11-17, after a full read of the repository.

## Where things stand

- The copy in daily use is 0.4.5 build 15 (2026-11-17), ad hoc signed, at
  `/Applications/Clipboard Archive.app`, installed with the published release
  folder's `install.sh`. That copy has no update helper inside it (only the
  disk image does), and no update feed exists, so "Check for Updates…" says
  updates are not available. The command-line tool there is 0.4.5 too.
- The public GitHub repository is current with `main`, and 0.4.5 is the
  published "latest" release. 0.4.2 fixed the installer, 0.4.3 lets a newer
  copy take over from an older one and repair the login item, 0.4.4 adds the
  archive write lock, and 0.4.5 fixes the keep-latest slowdown, the settings
  reset and the deletion ledger.
- Each install on the daily-use Mac was checked against its real data: every
  earlier history file byte-identical, settings unchanged, the data location
  carried over, one copy of the app, `verify` clean.
- 0.4.1 was checked three ways before it replaced 0.3.0 build 9: the test
  suite, a sandboxed scratch run of the release binary with a moved clock
  (a timed pause ends; the 0.3.0 binary stays paused in the same run), and one
  click-through on the installed copy (private mode started from the menu
  survives Save in an open Settings window).

## Finish line

For the 2026-11-17 review ("find everything that's broken, inconsistent,
inefficient, or no longer needed; fix what you're sure about and list the rest";
then "make sure the updating part doesn't make it so people lose their
stuff"). Written 2026-11-18. Each line names the check that shows it.

1. Every defect fixed has a test, and the whole gate passes at `main`:
   `scripts/check-all.sh --release` on a Mac ends "all checks passed".
2. An update keeps history, settings and the data location:
   `scripts/test-upgrade-keeps-data.sh` and `scripts/test-install-locations.sh`
   end "ok" (both are in the gate).
3. The public release is the code on `main`: the latest GitHub release is
   v0.4.5, its tag is the commit its disk image was built from, and the
   downloaded disk image's SHA-256 matches its `.sha256` file.
4. The daily-use Mac runs that release and has lost nothing:
   `clipboard-archive version` says 0.4.5 (15), `status` shows capture on with
   a recent capture, and `verify` ends "no problems found".
5. What was not fixed is listed for the owner with the reason: "Open
   decisions" and "Known gaps" below.
6. These docs say what is true now (this file, CHANGELOG, INSTALL, UPDATES).
7. Nothing from the review is left running: no scratch app, timer or helper.

## Checks

`scripts/check-all.sh` is the gate, run on a Mac: build, unit tests, core
checks, and the installer, upgrade and backup tests, all in scratch folders.
`scripts/check-all.sh --release` adds packaging and the release-folder
checks. Nothing runs it automatically: the workflow file needs a macOS runner
and none is set up. `test-release.sh` and `test-update-e2e.sh` cover the disk
image and the updater and are run by hand before a release that changes them.

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

- A restore into an empty archive copies the backup's day files over whatever
  is there. A clip captured into a new day file in the moments before that
  copy is replaced by the backup's file for the same day.
- The Settings window still saves its own copy of retention and app rules. A
  retention change made from the menu while it is open is overwritten by Save.
- The secret detector blocks some ordinary text (`sort_key=relevance1`,
  "send the recovery code instructions") and lets long all-hex tokens through.
  Both are judgment calls about what to block, not defects with one answer.
- `health` and `doctor` count deleted clips as stored, because the count is
  of timeline rows, which deleted clips keep.
- The status menu is rebuilt, reading today's day file, on every capture
  whether or not anyone opens it.
- An annotation edit made while History is reloading discards that reload.
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
