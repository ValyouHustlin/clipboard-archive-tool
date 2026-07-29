# Production Readiness Review

Review date: 2026-07-28

## Verdict

Clipboard Archive is now credible engineering for a private alpha, not a
finished paid product. The repository-level privacy and failure-safety blockers
found at baseline are fixed and exercised with synthetic fixtures. Public or
paid distribution remains blocked by Developer ID signing/notarization, an
external beta/support loop, and evidence that the positioning converts.

The installed build has run continuously for 21 days and archive metadata
showed current writes. That is useful durability evidence, not external product
validation.

No clipboard record or export content was read, printed, searched, sampled, or
summarized for this review. Live checks were limited to process state, settings
metadata, file counts, sizes, permissions, and timestamps. Every functional
archive/search/privacy check used synthetic fixtures authored by this lane.

## What Changed

- New profiles start with capture off and require a first-run choice: no
  capture, last 50 (recommended), or full archive.
- The disclosure names plaintext storage, the archive path, and the limits of
  password-manager/credential filtering.
- A standard Swift Testing target now covers filtering, blocked-content
  non-retention, traversal and symlink containment, redaction boundaries,
  owner-only permissions, health windows, daily manifests, legacy-settings
  migration, isolated development profiles, and derived-index failure behavior.
- Archive body paths are contained beneath the archive root before read or
  deletion. Absolute, traversal, and symlink-escape paths are rejected.
- App-created directories use mode `0700`; files use mode `0600`.
- Future events no longer inflate current health windows; daily manifests now
  contain day-scoped counts.
- SQLite rebuilds use a private sibling temporary database, run
  `/usr/bin/sqlite3` `quick_check`, and atomically replace the prior index only
  after success.
- Release packaging no longer writes over `dist/ClipboardArchive.app`.
- The release installer validates bundled checksums before stopping an app,
  stages replacement, and restores the previous app and LaunchAgent if the new
  app does not remain running.
- Clipboard-mutating stress scripts refuse to run while a Clipboard Archive
  process exists unless a deliberate override is supplied.

## Verification Receipts

Final `swift test` command and complete output:

```text
/usr/bin/xcrun swift test
[0/1] Planning build
Building for debugging...
[0/12] Write sources
[3/12] Write swift-version--1AB21518FC5DEDBE.txt
[5/13] Compiling ClipboardArchiveCore ClipboardDefaults.swift
[6/13] Emitting module ClipboardArchiveCore
[7/18] Compiling ClipboardArchiveCore ClipboardArchivePruner.swift
[8/18] Compiling ClipboardArchiveCore ClipboardArchiveRedactor.swift
[9/18] Compiling ClipboardArchiveCore ClipboardDerivedIndex.swift
[10/18] Compiling ClipboardArchiveCore ClipboardArchiveHealth.swift
[11/18] Compiling ClipboardArchiveCore ClipboardSettings.swift
[12/30] Compiling ClipboardArchiveChecks main.swift
[13/30] Emitting module ClipboardArchiveChecks
[13/31] Write Objects.LinkFileList
[15/31] Emitting module clipboard_archive
[16/31] Compiling clipboard_archive main.swift
[16/31] Write Objects.LinkFileList
[17/31] Linking clipboard-archive-checks
[18/31] Applying clipboard-archive-checks
[20/31] Emitting module ClipboardArchiveMenuBar
[21/31] Compiling ClipboardArchiveMenuBar AppInstanceLock.swift
[22/31] Compiling ClipboardArchiveMenuBar main.swift
[22/33] Linking clipboard-archive
[23/33] Applying clipboard-archive
[25/33] Compiling ClipboardArchiveMenuBar ClipboardOnboardingWindowController.swift
[26/33] Compiling ClipboardArchiveMenuBar ClipboardSettingsWindowController.swift
[26/33] Write Objects.LinkFileList
[28/33] Emitting module ClipboardArchiveCoreTests
[28/33] Linking ClipboardArchiveMenuBar
[29/33] Applying ClipboardArchiveMenuBar
[31/33] Compiling ClipboardArchiveCoreTests ClipboardArchiveCoreTests.swift
[31/33] Write Objects.LinkFileList
[32/33] Linking ClipboardArchivePackageTests
Build complete! (2.36s)
◇ Test run started.
↳ Testing Library Version: swift-6.2-DEVELOPMENT-SNAPSHOT-2025-12-03-a
◇ Suite "Clipboard Archive Core" started.
◇ Test testExistingIndexParentPermissionsAreNotChanged() started.
◇ Test testBearerTokenIsDetected() started.
◇ Test testDailyManifestContainsOnlyRequestedDayCounts() started.
◇ Test testWriterRejectsSymlinkedArchiveSubdirectory() started.
◇ Test testSymlinkEscapeIsRejected() started.
◇ Test testArchiveWriterUsesPrivateFilePermissions() started.
◇ Test testCommonCredentialFormatsAreDetected() started.
◇ Test testHealthReportsUnsafeBodyPaths() started.
◇ Test testIndexRebuildAndSearchRoundTrip() started.
◇ Test testKnownPasswordManagerSourcesAreBlocked() started.
◇ Test testLegacySettingsCompleteOnboardingWithoutChangingCapture() started.
◇ Test testFailedIndexRebuildPreservesExistingIndex() started.
◇ Test testReaderRejectsBodyPathOutsideArchiveRoot() started.
◇ Test testBlockedCaptureDoesNotPersistRawContent() started.
◇ Test testFutureEventsAreNotCountedInCurrentHealthWindows() started.
◇ Test testNewSettingsDefaultToCaptureOffAndLimitedRetention() started.
◇ Test testApplicationSupportRootCanBeIsolated() started.
◇ Test testRedactionNeverDeletesOutsideArchiveRoot() started.
◇ Test testOrdinaryWorkTextIsNotDetectedAsSecret() started.
✔ Test testNewSettingsDefaultToCaptureOffAndLimitedRetention() passed after 0.001 seconds.
✔ Test testLegacySettingsCompleteOnboardingWithoutChangingCapture() passed after 0.001 seconds.
✔ Test testApplicationSupportRootCanBeIsolated() passed after 0.001 seconds.
✔ Test testBearerTokenIsDetected() passed after 0.001 seconds.
✔ Test testKnownPasswordManagerSourcesAreBlocked() passed after 0.002 seconds.
✔ Test testOrdinaryWorkTextIsNotDetectedAsSecret() passed after 0.002 seconds.
✔ Test testReaderRejectsBodyPathOutsideArchiveRoot() passed after 0.002 seconds.
✔ Test testCommonCredentialFormatsAreDetected() passed after 0.003 seconds.
✔ Test testSymlinkEscapeIsRejected() passed after 0.003 seconds.
✔ Test testWriterRejectsSymlinkedArchiveSubdirectory() passed after 0.006 seconds.
✔ Test testBlockedCaptureDoesNotPersistRawContent() passed after 0.009 seconds.
✔ Test testArchiveWriterUsesPrivateFilePermissions() passed after 0.013 seconds.
✔ Test testHealthReportsUnsafeBodyPaths() passed after 0.014 seconds.
✔ Test testFailedIndexRebuildPreservesExistingIndex() passed after 0.014 seconds.
✔ Test testDailyManifestContainsOnlyRequestedDayCounts() passed after 0.015 seconds.
✔ Test testFutureEventsAreNotCountedInCurrentHealthWindows() passed after 0.014 seconds.
✔ Test testRedactionNeverDeletesOutsideArchiveRoot() passed after 0.014 seconds.
✔ Test testExistingIndexParentPermissionsAreNotChanged() passed after 0.022 seconds.
✔ Test testIndexRebuildAndSearchRoundTrip() passed after 0.025 seconds.
✔ Suite "Clipboard Archive Core" passed after 0.025 seconds.
✔ Test run with 19 tests in 1 suite passed after 0.026 seconds.
```

Compatibility runner:

```text
/usr/bin/xcrun swift run clipboard-archive-checks
24 named checks printed "ok"
all checks passed
```

Release package:

```text
./scripts/package-release.sh
release_dir: .../releases/ClipboardArchive-0.1.2-macos-arm64

./scripts/validate-release.sh releases/ClipboardArchive-0.1.2-macos-arm64
release validation ok

./scripts/check-local-only.sh releases/ClipboardArchive-0.1.2-macos-arm64
local-only check ok

./scripts/test-install-rollback.sh releases/ClipboardArchive-0.1.2-macos-arm64
install rollback test ok
```

The installed executable SHA-256 and mtime were identical before and after
packaging:

```text
SHA-256: 79a47482e4b121268b22d254eb5c29c208deb4be21061cd10d4c594622643a99
mtime: 1781205139
```

PID 1844 remained the running `dist/ClipboardArchive.app` executable. Both
clipboard-mutating stress scripts exited `2` with the message that they refused
to run while Clipboard Archive was active.

## UI Observation

An isolated debug app used separate synthetic archive, index, settings, and
lock roots. The onboarding window was rendered to a debug-only AppKit snapshot
and visually inspected. A debug-only `NSButton.performClick` selected
`Keep Last 50`; the window dismissed and the isolated settings file recorded:

```text
archiveEnabled: true
retentionMode: recent-50
recentItemLimit: 50
hasCompletedOnboarding: true
synthetic_archive_files: 0
```

macOS denied external Accessibility automation and window capture in this
session, so this was an in-process AppKit gesture, not a physical mouse click.
The native button labels did not appear in the cached-view PNG even though the
button action fired; external visual QA on a normally rendered signed build is
still required.

The first isolated run exposed that `UserDefaults` was not yet separated by
the Application Support override. Its automation may have written
`capturePaused=false` to the production preference domain; metadata inspection
afterward showed `0`, but there is no before-value receipt, so attribution is
unknown. The running PID was not affected. Isolated profiles now use a separate
preference suite, and the test covers that routing.

## Remaining Ship Gates

1. Sign with an owner-approved Developer ID identity, enable hardened runtime,
   notarize, and test Gatekeeper installation/update/rollback on a second Mac.
2. Run a small external beta with a support/privacy incident process and no
   request for participants' clipboard exports.
3. Observe first-run, daily recall, deletion, exclusions, and recovery using
   synthetic or participant-authored non-sensitive fixtures.
4. Validate willingness to pay before licensing, App Store, or broader polish
   work.

Bundled checksums protect against corruption or mismatched extracted files; the
checksum file travels with the artifact and therefore does not authenticate the
publisher.

## Historical Claims Not Re-Asserted

The prior review reported real-archive integrity, live production
capture/search, menu-bar stress, a 50,000-event benchmark, and full pipeline
results from 2026-05-15. This session did not inspect private archive contents,
mutate the live clipboard, replace the installed app, or rerun those flows.
They remain historical evidence rather than current verification.
