# Production Readiness Review

Review date: 2026-07-28

## Verdict

Clipboard Archive is a useful, proven personal tool, but the checked-in product
is not yet ready to charge strangers for.

The installed build has run continuously for 21 days and archive metadata shows
current writes. That is meaningful durability evidence. It is not a substitute
for a distributable product test: the repository has no runnable `swift test`
suite, no first-run privacy disclosure, no safe isolated UI fixture path, an
unsigned/unnotarized release, and several maintenance claims that were not
accurate when checked against the code.

No clipboard record or export content was inspected for this review. Live
checks were limited to process state, settings metadata, file counts, sizes,
and timestamps. Functional checks used synthetic fixtures authored by this
lane.

## Verified This Session

Exact baseline commands and observed results:

```text
/usr/bin/xcrun swift build
Build complete! (27.21s)

/usr/bin/xcrun swift test
error: no tests found; create a target in the 'Tests' directory

/usr/bin/xcrun swift run clipboard-archive-checks
24 named checks printed "ok"; final line: all checks passed

/usr/bin/xcrun swift run clipboard-archive self-test
self-test ok: <temporary synthetic fixture path>
```

A synthetic CLI fixture was searched through the archive reader, rebuilt into
SQLite, and searched through FTS successfully.

Launching the development menu-bar executable while the installed instance was
running exited without replacing it. PID 1844 remained the installed
`dist/ClipboardArchive.app` executable.

Metadata-only live observations:

- PID 1844 had 21 days of elapsed runtime.
- The LaunchAgent points to the repo's `dist/ClipboardArchive.app`.
- Settings reported full archive enabled, 0.2-second polling, and no configured
  app exclusions.
- The archive contained 140 files and its newest file timestamp was current
  within the session.
- The derived index file was about 19 MB and had not been modified since
  2026-06-11.

The stale index timestamp does not prove a failure: the app does not update the
derived index on every capture. It does prove the index is not an automatically
current search surface.

## Load-Bearing Strengths

- Filtering occurs before accepted-content archive writes.
- Blocked-event records omit clipboard text.
- Inline and large-body storage share one event model.
- Manual delete rewrites archived content, removes large-body files, records a
  ledger event, and attempts to purge the derived index.
- Retention modes physically redact pruned content rather than only hiding UI
  rows.
- The archive is local and machine-readable without a vendor service.
- The index is derived and rebuildable.
- The app uses a single-instance lock.
- The product and CLI have no app-runtime network client.
- Install/update behavior is explicit and separate from capture runtime.

## Blocking Product Gaps

### 1. No Real Test Target

`Tests/AIHubClipboardCoreTests` is empty and `Package.swift` defines no test
target. The custom check executable covers useful happy paths, but it is not
discovered by `swift test`, has no standard failure reporting, and leaves
temporary fixtures behind.

Privacy filtering, blocked-event non-retention, path containment, redaction,
pruning, health windows, manifest semantics, settings migration, index failure
behavior, and CLI integration need standard automated coverage.

### 2. First Run Starts Full Capture Without Disclosure

With no settings file, capture and unlimited retention default to on. A new user
is not shown where plaintext data is stored, what filtering cannot catch, or
how to choose limited retention before the first archived change.

For a clipboard product, informed first-run choice is part of the privacy
boundary.

### 3. Health Date Windows Accept Future Events

The health reporter counts any event at or after today's start as "today" and
any event at or after seven days ago as "last seven days." A future-dated
synthetic fixture was counted in both. Both windows need an upper bound.

### 4. "Daily" Manifests Contain All-Time Totals

`writeDailyManifest(for:)` copies all-time counts from `health()` into a file
named for one day. The manifest type and docs imply daily counts. This is a
semantic bug, not a wording preference.

### 5. Archive Body Paths Are Not Contained

Reader, search, health, redaction, pruning, and index rebuild append the
event-provided `rawContentPath` without validating that the standardized target
stays under the archive root. A malformed or tampered event could cause reads
or deletion outside the archive boundary.

### 6. Index Rebuild Is Destructive Before Success

Rebuild deletes the existing SQLite file before creating the replacement. If
`sqlite3` fails, the prior usable index is already gone. The new index should be
built at a sibling temporary path, validated, and atomically installed.

### 7. No Safe UI Fixture Mode

The instance lock correctly prevents a second normal app, but that means the UI
cannot be exercised against synthetic data while the live instance runs.
Settings and lock paths are fixed under Application Support even when archive
and index paths are overridden.

## Important Non-Blocking Gaps

- The window search filters loaded previews only; its label does not make the
  seven-day/preview-only boundary explicit.
- Index freshness is observable but not automatically repaired.
- App exclusions require users to know bundle identifiers.
- Source attribution is best-effort and no UI explains its uncertainty.
- Release artifacts are ad hoc signed, not Developer ID signed or notarized.
- There is no public crash/support/update operating loop for external users.
- The UI is functional but does not yet meet the polish of established paid
  clipboard products.

## Historical Claims Not Re-Asserted

The prior review said it had verified real archive integrity, live production
capture/search, LaunchAgent install behavior, menu-bar stress, a 50,000-event
benchmark, and a full pipeline report. Those may have been true on 2026-05-15,
but this session did not inspect private archive contents, rerun live clipboard
capture, replace the installed app, or find a current receipt that makes those
claims current. They are historical evidence, not present verification.

## Current Ship Gate

Before asking external users to trust or pay for Clipboard Archive:

1. Make `swift test` real and privacy-heavy.
2. Add first-run disclosure with an explicit retention choice before capture.
3. Contain every archive-relative path and prove the deletion boundary.
4. Correct health/manifest semantics.
5. Make index rebuild failure-safe.
6. Exercise the UI against synthetic data without touching the live archive.
7. Establish Developer ID signing/notarization and a low-data support path.
8. Validate the positioning with real target users before adding licensing or
   App Store scope.

The first six are repository work. Signing, public beta distribution, pricing,
and paid-product commitments remain owner decisions.
