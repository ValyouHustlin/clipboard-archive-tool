# Isolated app testing

Use `scripts/run-isolated-app.py /tmp/unique-root /absolute/path/to/ClipboardArchiveMenuBar` for app tests. The launcher sets the application-support, archive, index, and launch-agent paths, and applies a macOS sandbox that denies writes outside the scratch root and preference-daemon IPC. It does not install or register the app.

A support-root override selects file-backed preferences at `support/preferences.json` and a named pasteboard derived from that root before any pasteboard read. It also disables system-wide shortcuts, direct paste, login-item changes, window-frame autosave, external navigation, Accessibility prompts, and backup file dialogs. Separate roots have separate preferences and pasteboards. Production without an override retains its normal preferences and general pasteboard.

`CLIPBOARD_ARCHIVE_PASTEBOARD=general` overrides the named-pasteboard half of the
support-root override and binds the app to the REAL clipboard while its stores stay
isolated. It exists for harnesses that drive capture through `pbcopy`
(`scripts/stress-menu-bar-app.sh`), which cannot reach a named board. Anything else
isolating a run should leave it unset: with it set, a scratch app observes and archives
whatever is on the operator's real clipboard.

`support/clock.txt` optionally contains finite Unix epoch seconds. Calendar decisions, event timestamps, settings deadlines, archive manifests, and UI date filters use it. Timer scheduling and operation deadlines continue to use real elapsed time. Remove the file to use the system clock. In isolated runs, atomic file writes use a temporary file beside their destination; production retains Foundation's atomic writer.

A DEBUG build supports `CLIPBOARD_ARCHIVE_ISOLATION_RECEIPT=1`. It exercises private preferences and the named pasteboard, writes `support/isolation-receipt.json`, and exits. Existing UI automation also requires `CLIPBOARD_ARCHIVE_UI_SNAPSHOT_PATH` and its screen-specific parameters. All result/snapshot paths must stay inside the scratch root.

Do not run the CLI monitor during app testing: it uses the general pasteboard. Every CLI command, including help/version, must set these four paths:

```sh
CLIPBOARD_ARCHIVE_APPLICATION_SUPPORT_ROOT=/tmp/example/support \
CLIPBOARD_ARCHIVE_ARCHIVE_ROOT=/tmp/example/archive \
CLIPBOARD_ARCHIVE_INDEX_PATH=/tmp/example/index/search.sqlite \
CLIPBOARD_ARCHIVE_LAUNCH_AGENT_PLIST=/tmp/example/agent.plist \
/path/to/clipboard-archive status --json
```

## Health and recovery

`status` recomputes archive/index membership and SQLite integrity for the resolved stores. It reports `index_verified_at` only after a complete successful check; `fresh` means verified, not merely a recent modification time. This costs a full archive scan. It does not rebuild the index or quarantine settings during a status query.

Heartbeat health uses the process holding the app lock. Capture-enabled instances warn on zero polls after the 60-second startup allowance; paused/private instances are exempt. Heartbeats more than five seconds in the future are untrusted. Capture volume and resident memory remain diagnostic measurements, not workload-independent health thresholds.

Content-free unresolved capture/index failures are retained beside the Logs directory in `ClipboardArchive-operational-state.json`. Rotating or removing the log cannot clear them. A successful capture clears capture/append failures only; a successful index rebuild clears index failures. The historical 24-hour error count remains visible after recovery. Health-query warning exit codes are logged as warnings, avoiding a feedback loop.

Settings must include their capture choice. Historical files can omit fields introduced later. When a last-good copy exists, losing its policy fields is treated as suspicious truncation. Invalid numeric ranges and unsupported versions trigger visible recovery instead of silent clamping. Read-only status checks leave the original file in place.

SQLite bulk loading has a four-second monotonic subprocess deadline, adjustable by the core caller through `sqliteTimeoutSeconds`. The subprocess gets its own process group; timeout kills that group and reaps the direct child. Failed rebuilds leave the prior index in place.

Empty backup restores are refused. Successful nonempty restores that pass verification record `restore-verification.json` beside settings, bound to the destination archive path and directory identity. Status exposes `last_successful_restore_verified_at`; the restore command reports `restore_verified_at`, or `unavailable` if verification or evidence recording did not finish. The receipt is diagnostic metadata and is not part of the backup's archive bytes.

If settings are unreadable and no valid last-good copy exists, the app does not apply substituted retention defaults. Automatic metadata saves (including What's New/version tracking and duplicate grouping) leave the unreadable settings in place. A successful full Settings save or explicit onboarding privacy/retention choice restores eligibility for automatic retention.
