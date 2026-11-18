# Next Session Handoff

Updated: 2026-11-18, after a full read of the repository and five releases.

## Where things stand

- The copy in daily use is 0.4.5 build 15 (2026-11-17), ad hoc signed, at
  `/Applications/Clipboard Archive.app`, installed with the published release
  folder's `install.sh`. That copy has no update helper inside it (only the
  disk image does), and no update feed exists, so "Check for Updates…" says
  updates are not available. The command-line tool there is 0.4.5 too.
- The public GitHub repository is current with `main`, and 0.4.5 is the
  published "latest" release. 0.4.1 fixed the pause, private-mode and expiry
  defects; 0.4.2 fixed the installer; 0.4.3 lets a newer copy take over from
  an older one and repair the login item; 0.4.4 adds the archive write lock;
  0.4.5 fixes the keep-latest slowdown, the settings reset and the deletion
  ledger.
- `main` is ahead of 0.4.5 by tests, docs and the two small changes under
  "Not yet released".

## Finish line

For the 2026-11-17 review ("find everything that's broken, inconsistent,
inefficient, or no longer needed; fix what you're sure about and list the rest";
then "make sure the updating part doesn't make it so people lose their
stuff"). Each line names the check that shows it, and says where a check stops.

1. The gate passes at `main`: `scripts/check-all.sh --release` on a Mac ends
   "all checks passed". Every fix in the library and the command-line tool has
   a test in it. Fixes in the app's windows and menus do not, because nothing
   here drives the app's interface; they are listed under "Checked by hand".
2. The installer keeps history, pins, tags, the deletion record, settings and
   the data location: `scripts/test-upgrade-keeps-data.sh` installs over the
   state 0.1.2 and 0.4.4 leave behind, compares those files byte for byte, and
   reads them back with today's command-line tool. It uses a stub app, so it
   proves the installer and the tool, not the app.
3. The app keeps every setting on its first launch after an update:
   `SettingsUpgradeTests` covers the load and the save, and on 2026-11-18 the
   real 0.4.5 app was launched in a sandboxed scratch root over a 0.1.2 file,
   a 0.4.4 file with every later setting changed, and a capture-off file. No
   earlier choice changed in any of them.
4. The public release is the code it claims: the latest GitHub release is
   v0.4.5, its tag is the commit its disk image was built from, and the
   downloaded disk image's SHA-256 matches its `.sha256` file.
5. The daily-use Mac runs that release and is healthy:
   `clipboard-archive version` says 0.4.5 (15), `status` shows capture on with
   a recent capture, and `verify` ends "no problems found". At each of the
   three installer updates on 2026-11-17 (0.4.3, 0.4.4, 0.4.5) every
   earlier-day history file, more than 500 of them, was compared byte for
   byte before and after, and the settings field by field; nothing differed
   but the version stamp. The 0.4.1 install compared the settings only.
6. What was not fixed is listed with the reason: "Open decisions" and "Known
   gaps" below.
7. The docs say what is true now: this file, README, CHANGELOG, INSTALL,
   UPDATES.
8. Nothing from the review is left running: no scratch app, timer or helper.

## What the review covered

All 178 tracked files were read in full. Removed as no longer needed: helpers
nothing called, the tracked link to an ignored file, the old-name test folder,
three internal planning docs (moved to the ignored `docs/internal/`),
workstation paths and names in public docs, and on the daily-use Mac the
pre-rename app bundle and support folders plus about 2 GB of test scratch.
Judged unused and kept, because they pair with a private install script on
that Mac: `scripts/login-agent-status.sh` and `scripts/uninstall-login-agent.sh`.
The five `scripts/dev-run-*-harness.sh` receipts and
`scripts/check-archive-integrity.sh` (a weaker `verify`) are also unused by
the gate and were left in place.

## Checks

`scripts/check-all.sh` is the gate, run on a Mac: build, unit tests, core
checks, the command lines the tool must refuse, and the installer, upgrade
and backup tests, all in scratch folders. `scripts/check-all.sh --release`
adds packaging and the release-folder checks. Nothing runs it automatically:
the workflow file needs a macOS runner and none is set up. `test-release.sh`
and `test-update-e2e.sh` cover the disk image and the updater and are run by
hand before a release that changes them.

### Checked by hand

No automated test drives the app's interface, so these were checked once and
would not be caught again by the gate:

- A timed pause ends on time, and a newer copy takes over from an older one
  and repairs the login item: run in scratch with the real app bundles. The
  takeover must be run with the four path variables and without
  `run-isolated-app.py`, whose sandbox blocks the quit request one app sends
  the other.
- Private mode survives Save in an open Settings window: clicked through on
  the installed copy.
- Not checked at all: the shortcut recorder stopping when Settings hides, an
  open History window reloading after a delete from the menu, Rebuild Search
  Index running off the main thread, and one expiry sweep at a time. Each is
  a few lines read for correctness and compiled, nothing more.

## What an update keeps, and what it does not

Kept: history, pins and tags, the deletion record, every setting, and the
data location. The installer never writes inside the archive or the settings
file; it carries the data location over from the login item it replaces. The
app reads archives and search indexes back to 0.1.2. A newer copy dragged in
from the disk image beside an older folder install takes over from it and
points the login item at itself (`ClipboardInstallRepair`, carried out in
`InstallRepairRunner`); it leaves the older copy on disk.

Not seamless, and why:

- macOS ties the Accessibility permission to the exact build while releases
  are ad hoc signed. After any update, direct paste needs approving again.
  Only Developer ID signing fixes this.
- A downloaded disk image needs "Open Anyway" each time, for the same reason.
- Dragging the disk image does not update the command-line tool in
  `~/.local/bin`; `install.sh` does.
- No copy updates itself. The update helper exists, but no release has been
  built with an update feed.
- The pause switch lives in the system's preferences for the app, which macOS
  keeps across an update; nothing here tests that.
- Nothing tests going back to an older version.

## Not yet released

On `main` after 0.4.5; add to the next release's CHANGELOG entry:

- `clipboard-archive self-test` removes the scratch archive it writes.
- The `.tar.gz` package no longer carries macOS "._" side files.

## Open decisions

Each has a default that needs no action.

1. Where the update feed is hosted. Options: GitHub Releases (the URL the docs
   already sketch), or nowhere. Default: nowhere; updates stay manual.
2. Developer ID signing and notarization ($99 a year). It removes "Open
   Anyway" and the Accessibility re-approval. Default: stay ad hoc signed.
3. LICENSE is MIT with copyright "Clipboard Archive contributors". Options:
   keep, or name the owner. Default: keep.
4. Where CI runs: a Mac runner, or `check-all.sh` by hand. Default: by hand.
5. What the secret detector blocks. It stops some ordinary text
   (`sort_key=relevance1`, "send the recovery code instructions") and lets
   long all-hex tokens through. Tightening one loosens the other. Default:
   leave it; a wrongly blocked clip is safer than a stored credential.
6. Whether `health` and `doctor` should count deleted clips as stored. They
   count timeline rows, which deleted clips keep. Default: leave it.

## Known gaps, not yet fixed

Each says why it was left.

- The Settings window saves its own copy of retention and app rules, so a
  retention change made from the menu while it is open is overwritten by Save.
  Left because the fix changes what Save means and cannot be checked without
  clicking through the app.
- An annotation edit made while History is reloading discards that reload.
  Left for the same reason: it is a timing fault in the window code.
- The status menu is rebuilt, reading today's day file, on every capture
  whether or not anyone opens it. Left because building it on demand is a
  rewrite of the menu code; the cost is a few milliseconds per copy.
- A restore into an empty archive copies the backup's day files over whatever
  is there, so a clip captured into a new day file moments before is
  replaced. Left because it needs a restore into an empty archive while
  capture is running, and the fix changes what a verified restore contains.
- `health` reads the whole archive three times. Left as a slow report, not a
  fault.
- Old builds that redact a rich clip leave its body file behind; `health`
  counts these as `orphanedRichBodyFiles`. Left because only an old build
  creates them.
- The private mirror still holds twelve merged branches. Left because the
  mirror refuses deletions on purpose.
- Manual checks that need a real session: global hotkey registration and
  conflicts, direct paste with Accessibility trust, launch at login from an
  installed app.

## Ground rules that still apply

Do not read clipboard contents from the real archive or indexes for
development or tests. All development and testing uses isolated `/tmp` roots
through the four `CLIPBOARD_ARCHIVE_*` path variables
([ISOLATED_TESTING.md](ISOLATED_TESTING.md)) and synthetic fixtures. Do not
stop or replace the live app, install login items, or start live capture
without explicit approval. `check-local-only.sh` is the network-abstinence
gate; keep it green. Commit as "Clipboard Archive Maintainers" with the
no-reply address (set per checkout), and build made-up credentials for tests
from pieces at run time: GitHub's push protection scans every push.
