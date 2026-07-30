# Bulk Management, Privacy Upgrades, Storage Dashboard — Implementation Design

Status: approved by lead 2026-07-30. Implements contracts 4/5/6/10 (feature
matrix rows 5, 9, 10). Sequenced strictly AFTER the Slice 4 merge.

## `.restricted` semantics (binding decision)

`.restricted` = **stored, visible, never searchable.**
- Stays in archive; retention/prune/redact/bulk apply normally.
- Visible on reader-backed surfaces (menu, This Window, quick picker) with
  an `eye.slash` "Restricted" badge; content opens and copies normally.
- Never enters the derived index: upsert deletes-instead-of-inserts,
  rebuild skips, CLI searcher skips. All History footer: "Restricted clips
  are hidden from search."
- Wiring: `ClipboardSuppression` gains a SECOND named predicate
  `isIndexExcluded(event, sensitivityOverride:)` (= doNotIndex || restricted
  || override=="restricted") alongside the untouched visibility gate
  `isSuppressed`. One gate file, two tested predicates — NOT a third
  mechanism, and NOT added to isSuppressed (that would silently turn "mark
  sensitive" into "delete").
- Producers: (a) per-app rule `store-no-index` writes `.restricted` at
  capture (+ flag `app-rule-no-index`); (b) manual sensitivity sets
  `sensitivityOverride: "restricted"` in annotations (event lines never
  rewritten; survives re-copies via contentHash). Ingestor consults the
  stat-validated annotations cache pre-upsert; re-copies of overridden
  content skip indexing (+ flag `manual-restricted`).
- Tombstones remain `.doNotIndex`. Marking restricted on an existing clip
  → occurrenceIDs → index.delete; clearing re-upserts occurrences.

## Settings/rules shapes (tolerant decode, defaults = current behavior)

```json
"settingsVersion": 1,
"appPrivacyRules": { "com.example.crm": { "mode": "store-no-index", "addedAt": "..." } },
"privateModeUntil": null,
"showBlockedEventStatus": true
```

- `ClipboardAppPrivacyRule.mode` is a RAW string round-tripped losslessly;
  known: normal | store-no-index | block; UNKNOWN evaluates as block (fail
  closed) but re-encodes unchanged. Keys = lowercased bundle ids.
- Filter precedence (doc-commented + fixture-tested): 1 pasteboard-type
  denylist (no override) → 2 built-in password-manager lists (a "normal"
  rule cannot override; UI says so) → 3 explicit appPrivacyRules → 4 legacy
  exclusion lists (only when no explicit rule) → 5 secret detector.
- Downgrade fail-closed: saving store-no-index ALSO keeps the bundle in
  excludedBundleIdentifiers (older builds block outright — stricter, never
  looser); a "normal" rule removes the legacy entry. CHANGELOG-documented.
- New blocked reason family `app_rule_block:<bundleid>`.
- Annotations placeholders go live: setSensitivityOverride, setExpiry,
  entriesWithExpiry, earliestExpiry; GC rule keeps records with only
  override/expiry set.

## Bulk engine (new ClipboardBulkEngine.swift)

- `ClipboardBulkCriteria { eventIDs?, since?, until?, bundleID?,
  sourceAppName?, contentType?, sensitivity? (.anyFlagged |
  .manualRestricted), includePinned = false }`;
  `ledgerReason = "bulk-" + sorted active criterion keys`.
- `ClipboardBulkResult { matchedEvents, reclaimedBytes, deletedBodyFiles,
  changedFiles, exemptedPinnedEvents, removedAnnotationHashes, dryRun,
  reason }`.
- PARITY BY CONSTRUCTION: preview and execute call ONE private
  `run(_:dryRun:)` → one compiled predicate → the extended pruner core.
  No selection logic outside this path; parity test seals it.
- Truthful reclaimedBytes: stat existing body files (both modes, same call
  site); tombstone line ENCODED in both modes, `reclaimed += originalLine
  bytes - tombstone bytes`. Never estimated from event.byteCount.
- Day-range bounds the file scan (filename date mapping). Index cleanup =
  batched delete(eventIDs:) BEFORE tombstoning (fail-closed ordering).
  Post-execute: removeContentReference for hashes with no survivors.

## Pruner extension

Core promoted with `exemptContentHashes` + `restrictToDayRange` +
`reclaimedBytes` in ClipboardPruneResult; core's trailing full rebuild
replaced by pre-tombstone batched index delete. Public wrappers unchanged
beyond Slice 4's includePinned. Every destructive op (bulk sheet,
multi-select delete, dashboard cleanup, expiry sweep) flows through this
core or redactor.redact — nothing else writes tombstones.

## Expiry sweep (new ClipboardExpirySweeper.swift)

- `nextDue()` = annotations cache read only (zero archive IO);
  `sweepIfDue(now:)`.
- Enforcement points: app launch; 30-min timer (tick = one stat when clean);
  lazy check on window/picker/dashboard open. NOT on the capture poll; NOT
  read-time hiding (would be a third suppression mechanism). Settings copy
  states enforcement honestly.
- Sweep: per due hash → occurrenceIDs (suppression-filtered; reader-scan
  fallback) → bulk execute with includePinned: true, reason
  `expired-sensitive` (expiry is the user's explicit instruction — stated
  when setting expiry on a pinned clip) → clear annotation.
- UI: detail pane + context menu "Mark Sensitive" submenu (Restricted
  toggle, Expire in 1h/1d/7d, Clear Sensitivity).

## Timed private mode + pause fix

DISCOVERED PRE-EXISTING PRIVACY BUG (this slice fixes it): pause exit never
resyncs lastChangeCount, so the last item copied DURING a pause is
retro-captured on resume. Fix: on pause/private-mode exit, set
lastChangeCount/lastContentHash from the current pasteboard WITHOUT
ingesting.

Private mode (`privateModeUntil`): capture loop returns before reading the
pasteboard — no stored events, no blocked-event metadata lines (guaranteed
structurally: evaluation never runs). Exit resync as above. Menu "Private
Mode" submenu (15m/1h/until tomorrow/end), icon `eye.slash`, status
"Private until HH:MM". Pause remains, independent key; either stops
capture; Settings copy explains the difference.

## Dashboard + blocked explanations + bulk UI

- Separate "Storage & Health" WINDOW (new ClipboardDashboardWindowController)
  — Settings is full; reached from Maintenance menu (replaces the health
  NSAlert) and a button on the Local Storage card. Sections: Overview
  (extended health: bodyFileBytes, eventFileCount, oldestCapturedAt,
  restrictedEvents, pinnedItems, taggedItems, expiringItems,
  indexUserVersion, annotationsBytes — computed off-main), Recent Blocked
  Items (new reader.recentBlockedEvents(since:limit:) + new
  ClipboardBlockedEventExplainer.swift humanizing machine reasons), 
  Maintenance (rebuild index with inline receipt, verify integrity =
  quick_check + health summary), Cleanup (prune-by-age with preview via
  bulk engine; Delete enabled only after preview; "Bulk Cleanup…" opens the
  sheet).
- Settings window: Exclusions card becomes "App Privacy Rules" (same table
  + per-row mode popup; legacy entries render Block); Local Storage card
  gains the dashboard button. Optional menu status line "Last blocked: X —
  password manager rule" behind showBlockedEventStatus.
- Bulk sheet (new ClipboardBulkSheetController): date/app/type/sensitivity
  popups, Preview button, result line, "Include pinned" checkbox firing its
  own confirmation quoting exemptedPinnedEvents (the contract-5 separate
  confirm), Delete disabled until preview matches current criteria hash
  (any edit invalidates). Background-queue execution; completion refreshes
  History + dirties the quick-picker cache.
- History multi-select delete rerouted through the engine with truthful
  preview in the confirm ("Delete 14 clips, reclaiming 212 KB? This cannot
  be undone.") composed with Slice 4's pinned warning.
- CLI: new `bulk` (--until/--since/--bundle-id/--app/--type/--sensitivity/
  --include-pinned/--dry-run/--json) and `sweep-expired`; health prints new
  fields.

## Test plan

BulkEngineTests (parity incl. on-disk byte-delta truth test; every
criterion; pinned exemption + includePinned; ledger reasons; stale-drift
no-double-count; tombstone field-equality with redactor; day-range mtime
bounds). PrivacyRulesTests (per mode: allowed/blocked/false-positive/
non-retention byte-compare; precedence; unknown-mode fail-closed
round-trip; store-no-index legacy write). RestrictedSemanticsTests
(visible in recentItems; absent from rebuild/upsert/search/browse/CLI
searcher; override re-copy unindexed; isSuppressed false while
isIndexExcluded true; clear re-indexes). ExpirySweeperTests (due/not-due;
nextDue zero-IO; sweeps pinned; ledger reason; index-absent fallback).
PrivateModeTests (nothing stored/blocked during; exit resync = no
retro-capture; pause gets same fix). Settings migration + health reporter
additions.

Harness screens: `bulk` (preview/toggle-include-pinned/execute + JSON
proving preview==execute), `dashboard` (render + humanized reason),
history extension (mark-restricted / set-expiry-past / sweep receipts),
settings rules row render, private-mode receipt
{storedDuring:0, blockedDuring:0, storedAfterResume:0}.

## Implementation order

Settings rules → isIndexExcluded + restricted wiring + tests → filter
precedence → annotations activation + sweeper → pruner core + bulk engine →
private mode + pause resync fix → health/explainer → UI (sheet, dashboard,
rules card, badges, reroute) → CLI → harness + docs (PRIVACY.md,
architecture.md, CHANGELOG).

## Top risks

| Risk | Mitigation |
|---|---|
| Preview/execute drift under live capture | re-evaluated predicate at execute; honest result numbers; harness receipt |
| Restricted invisibility in All History surprises | footer note + badge + wording at set time |
| Big bulk on main thread | background queue, day-range bounds, one sqlite call |
| Unknown rule mode weakens privacy | fail-closed block + lossless round-trip |
| Expiry while app closed | honest copy; unconditional launch sweep |
| Capture-path latency | existing stat-validated caches only; 50k benchmark re-run as gate |
