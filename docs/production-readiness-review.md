# Production Readiness Review

Review date: 2026-07-29

## Verdict

Clipboard Archive is credible engineering for Aaron's daily use and a useful
open-source project. Aaron does not want a paid-product push; the current goal
is a polished personal tool that others can download after seeing it on X.
Commercial validation is therefore no longer a roadmap gate.

The repository-level privacy and failure-safety blockers found at baseline are
fixed and exercised with synthetic fixtures. A frictionless download for
ordinary Mac users still needs Developer ID signing/notarization and a tested
GitHub Release artifact; source builds and explicitly trusted unsigned builds
remain viable for technical users.

The installed build has run continuously for 22 days and archive metadata
showed current writes. That is useful durability evidence, not external product
validation.

No clipboard record or export content was read, printed, searched, sampled, or
summarized for this review. Live checks were limited to process state, settings
metadata, file counts, sizes, permissions, and timestamps. Every functional
archive/search/privacy check used synthetic fixtures authored by this lane.

## What Changed

- New profiles start with capture off and require a first-run choice: no
  capture, last 50 (recommended), or full archive.
- Standard concealed/transient/password-manager pasteboard types are blocked
  before source-app and text-pattern checks.
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
- Accepted captures now upsert one SQLite FTS row in a short transaction.
  Clipboard text is streamed over standard input rather than exposed in process
  arguments, and an index error cannot fail the successful archive write.
  Owner-only cross-process locking prevents rebuild/upsert replacement races.
- Release packaging no longer writes over `dist/ClipboardArchive.app`.
- The release installer validates bundled checksums before stopping an app,
  stages replacement, and restores the previous app and LaunchAgent if the new
  app does not remain running.
- Clipboard-mutating stress scripts refuse to run while a Clipboard Archive
  process exists unless a deliberate override is supplied.
- The history window is now the product's home surface: rich recent rows,
  in-window search, full-content detail, multi-select copy, and local deletion.
- Menu search now focuses the history window instead of opening a second modal
  search flow; the menu shows five quick-copy clips and moves occasional
  controls under Maintenance.
- First-run and Settings were rewritten around understandable privacy,
  retention, exclusion, and local-storage choices.
- Debug UI automation refuses non-`/tmp` archive/support roots and authors only
  synthetic fixtures.

## Verification Receipts

Final UI-polish test run:

```text
/usr/bin/xcrun swift test
[0/1] Planning build
Building for debugging...
[0/9] Write sources
[1/9] Write swift-version--1AB21518FC5DEDBE.txt
[3/6] Emitting module ClipboardArchiveMenuBar
[4/6] Compiling ClipboardArchiveMenuBar main.swift
[4/7] Write Objects.LinkFileList
[5/7] Linking ClipboardArchiveMenuBar
[6/7] Applying ClipboardArchiveMenuBar
Build complete! (0.87s)
◇ Test run started.
↳ Testing Library Version: swift-6.2-DEVELOPMENT-SNAPSHOT-2025-12-03-a
◇ Suite "Clipboard Archive Core" started.
◇ Test testArchiveWriterUsesPrivateFilePermissions() started.
◇ Test testFutureEventsAreNotCountedInCurrentHealthWindows() started.
◇ Test testKnownPasswordManagerSourcesAreBlocked() started.
◇ Test testOrdinaryWorkTextIsNotDetectedAsSecret() started.
◇ Test testFailedIndexRebuildPreservesExistingIndex() started.
◇ Test testHealthReportsUnsafeBodyPaths() started.
◇ Test testWriterRejectsSymlinkedArchiveSubdirectory() started.
◇ Test testIndexRebuildAndSearchRoundTrip() started.
◇ Test testCommonCredentialFormatsAreDetected() started.
◇ Test testSymlinkEscapeIsRejected() started.
◇ Test testReaderRejectsBodyPathOutsideArchiveRoot() started.
◇ Test testApplicationSupportRootCanBeIsolated() started.
◇ Test testRedactionNeverDeletesOutsideArchiveRoot() started.
◇ Test testDailyManifestContainsOnlyRequestedDayCounts() started.
◇ Test testConfidentialPasteboardTypesAreBlocked() started.
◇ Test testBearerTokenIsDetected() started.
◇ Test testLegacySettingsCompleteOnboardingWithoutChangingCapture() started.
◇ Test testNewSettingsDefaultToCaptureOffAndLimitedRetention() started.
◇ Test testExistingIndexParentPermissionsAreNotChanged() started.
◇ Test testBlockedCaptureDoesNotPersistRawContent() started.
✔ Test testApplicationSupportRootCanBeIsolated() passed after 0.001 seconds.
✔ Test testNewSettingsDefaultToCaptureOffAndLimitedRetention() passed after 0.001 seconds.
✔ Test testLegacySettingsCompleteOnboardingWithoutChangingCapture() passed after 0.001 seconds.
✔ Test testBearerTokenIsDetected() passed after 0.001 seconds.
✔ Test testReaderRejectsBodyPathOutsideArchiveRoot() passed after 0.002 seconds.
✔ Test testKnownPasswordManagerSourcesAreBlocked() passed after 0.002 seconds.
✔ Test testOrdinaryWorkTextIsNotDetectedAsSecret() passed after 0.002 seconds.
✔ Test testCommonCredentialFormatsAreDetected() passed after 0.002 seconds.
✔ Test testSymlinkEscapeIsRejected() passed after 0.003 seconds.
✔ Test testWriterRejectsSymlinkedArchiveSubdirectory() passed after 0.006 seconds.
✔ Test testConfidentialPasteboardTypesAreBlocked() passed after 0.010 seconds.
✔ Test testBlockedCaptureDoesNotPersistRawContent() passed after 0.010 seconds.
✔ Test testFailedIndexRebuildPreservesExistingIndex() passed after 0.013 seconds.
✔ Test testHealthReportsUnsafeBodyPaths() passed after 0.013 seconds.
✔ Test testArchiveWriterUsesPrivateFilePermissions() passed after 0.014 seconds.
✔ Test testFutureEventsAreNotCountedInCurrentHealthWindows() passed after 0.014 seconds.
✔ Test testRedactionNeverDeletesOutsideArchiveRoot() passed after 0.014 seconds.
✔ Test testDailyManifestContainsOnlyRequestedDayCounts() passed after 0.014 seconds.
✔ Test testExistingIndexParentPermissionsAreNotChanged() passed after 0.018 seconds.
✔ Test testIndexRebuildAndSearchRoundTrip() passed after 0.022 seconds.
✔ Suite "Clipboard Archive Core" passed after 0.022 seconds.
✔ Test run with 20 tests in 1 suite passed after 0.022 seconds.
```

Final compatibility and package receipts:

```text
/usr/bin/xcrun swift run clipboard-archive-checks
24 named checks printed "ok"
all checks passed

./scripts/validate-release.sh releases/ClipboardArchive-0.1.2-macos-arm64
release validation ok
release_dir: releases/ClipboardArchive-0.1.2-macos-arm64

./scripts/check-local-only.sh releases/ClipboardArchive-0.1.2-macos-arm64
local-only check ok
release_dir: releases/ClipboardArchive-0.1.2-macos-arm64
```

The live installed executable remained unchanged after the build and package
flow (`SHA-256 79a47482…643a99`, `mtime 1781205139`, `size 852448`), and PID
1844 still pointed at `dist/ClipboardArchive.app`.

Phase 4 `swift test` command and complete output:

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

Market review then exposed the missing confidential-pasteboard-type signal.
After adding that test, the final test-run portion was:

```text
◇ Test run started.
↳ Testing Library Version: swift-6.2-DEVELOPMENT-SNAPSHOT-2025-12-03-a
◇ Suite "Clipboard Archive Core" started.
◇ Test testHealthReportsUnsafeBodyPaths() started.
◇ Test testBearerTokenIsDetected() started.
◇ Test testLegacySettingsCompleteOnboardingWithoutChangingCapture() started.
◇ Test testFailedIndexRebuildPreservesExistingIndex() started.
◇ Test testApplicationSupportRootCanBeIsolated() started.
◇ Test testWriterRejectsSymlinkedArchiveSubdirectory() started.
◇ Test testOrdinaryWorkTextIsNotDetectedAsSecret() started.
◇ Test testKnownPasswordManagerSourcesAreBlocked() started.
◇ Test testFutureEventsAreNotCountedInCurrentHealthWindows() started.
◇ Test testIndexRebuildAndSearchRoundTrip() started.
◇ Test testNewSettingsDefaultToCaptureOffAndLimitedRetention() started.
◇ Test testExistingIndexParentPermissionsAreNotChanged() started.
◇ Test testCommonCredentialFormatsAreDetected() started.
◇ Test testReaderRejectsBodyPathOutsideArchiveRoot() started.
◇ Test testRedactionNeverDeletesOutsideArchiveRoot() started.
◇ Test testDailyManifestContainsOnlyRequestedDayCounts() started.
◇ Test testBlockedCaptureDoesNotPersistRawContent() started.
◇ Test testArchiveWriterUsesPrivateFilePermissions() started.
◇ Test testSymlinkEscapeIsRejected() started.
✔ Test testApplicationSupportRootCanBeIsolated() passed after 0.001 seconds.
◇ Test testConfidentialPasteboardTypesAreBlocked() started.
✔ Test testNewSettingsDefaultToCaptureOffAndLimitedRetention() passed after 0.001 seconds.
✔ Test testLegacySettingsCompleteOnboardingWithoutChangingCapture() passed after 0.001 seconds.
✔ Test testBearerTokenIsDetected() passed after 0.001 seconds.
✔ Test testOrdinaryWorkTextIsNotDetectedAsSecret() passed after 0.002 seconds.
✔ Test testKnownPasswordManagerSourcesAreBlocked() passed after 0.002 seconds.
✔ Test testReaderRejectsBodyPathOutsideArchiveRoot() passed after 0.002 seconds.
✔ Test testCommonCredentialFormatsAreDetected() passed after 0.003 seconds.
✔ Test testSymlinkEscapeIsRejected() passed after 0.004 seconds.
✔ Test testWriterRejectsSymlinkedArchiveSubdirectory() passed after 0.005 seconds.
✔ Test testBlockedCaptureDoesNotPersistRawContent() passed after 0.012 seconds.
✔ Test testConfidentialPasteboardTypesAreBlocked() passed after 0.011 seconds.
✔ Test testHealthReportsUnsafeBodyPaths() passed after 0.015 seconds.
✔ Test testArchiveWriterUsesPrivateFilePermissions() passed after 0.015 seconds.
✔ Test testFailedIndexRebuildPreservesExistingIndex() passed after 0.015 seconds.
✔ Test testFutureEventsAreNotCountedInCurrentHealthWindows() passed after 0.016 seconds.
✔ Test testRedactionNeverDeletesOutsideArchiveRoot() passed after 0.016 seconds.
✔ Test testDailyManifestContainsOnlyRequestedDayCounts() passed after 0.016 seconds.
✔ Test testExistingIndexParentPermissionsAreNotChanged() passed after 0.021 seconds.
✔ Test testIndexRebuildAndSearchRoundTrip() passed after 0.024 seconds.
✔ Suite "Clipboard Archive Core" passed after 0.025 seconds.
✔ Test run with 20 tests in 1 suite passed after 0.025 seconds.
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

Incremental-index follow-up receipts used synthetic fixtures only:

```text
/usr/bin/xcrun swift test
✔ Test testIncrementalIndexStaysCurrentAcrossCaptureBurst() passed after 0.227 seconds.
✔ Suite "Clipboard Archive Core" passed after 0.227 seconds.
✔ Test run with 25 tests in 1 suite passed after 0.228 seconds.

/usr/bin/xcrun swift run clipboard-archive-checks
ok - accepted capture updates derived index incrementally
ok - index failure does not block accepted capture
all checks passed
```

The 50-capture synthetic burst produced 50 unique index rows, left
`indexIsStale` false, and left archive/index files owner-only. No live
clipboard value or real archive content was used.

## UI Observation

On 2026-07-29, all three primary surfaces were driven in isolated debug
instances using separate `/tmp` archive, index, settings, lock, and preference
roots. The history instance authored five synthetic clips (text, URL, and code)
and displayed them in the split view; selecting the first row displayed its
synthetic full content and metadata in the detail pane. Settings and onboarding
were rendered from isolated settings only. No real archive or export was
opened, searched, sampled, printed, or summarized.

The rendered pass caught two layout defects—a split view constrained to its
intrinsic width and an overemphasized onboarding privacy panel—which were fixed
before the final verification run. A debug search gesture filters the same
synthetic history list used by the normal window.

Owner review then rejected the first split-view composition as visually
unbalanced. A second isolated pass moved search/count into a real sidebar,
left-aligned clip rows, attached actions to the selection header, made preview
height content-aware, and reset the saved window geometry for the new layout.
The snapshot harness was also changed to render without app activation; a live
check observed the same foreground application before and after both normal and
filtered synthetic renders.

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

## Remaining Open-Source Download Gates

1. If the X link should be one-click friendly for nontechnical users, sign with
   an owner-approved Developer ID identity, enable hardened runtime, notarize,
   and test Gatekeeper installation/update/rollback on a second Mac.
2. Publish a versioned GitHub Release with checksums and concise install,
   privacy, and uninstall guidance.
3. Have one outside user exercise first-run, recall, deletion, exclusions, and
   recovery using only synthetic or participant-authored non-sensitive text.

Bundled checksums protect against corruption or mismatched extracted files; the
checksum file travels with the artifact and therefore does not authenticate the
publisher.

## Historical Claims Not Re-Asserted

The prior review reported real-archive integrity, live production
capture/search, menu-bar stress, a 50,000-event benchmark, and full pipeline
results from 2026-05-15. This session did not inspect private archive contents,
mutate the live clipboard, replace the installed app, or rerun those flows.
They remain historical evidence rather than current verification.
