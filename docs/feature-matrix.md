# Feature Expansion Matrix

Living status document for the 2026-07 complete feature expansion. Updated at
every integration checkpoint. Contracts: `docs/expansion-contracts.md`.
Brief: `docs/feature-expansion-handoff-2026-07-30.md`.

Legend: status = planned | in-progress | integrated | verified.
"Verified" requires the exact receipts named in the Verification column.

| # | Feature | Source surfaces | Migration | Tests | Runtime verification | Status |
|---|---------|-----------------|-----------|-------|----------------------|--------|
| 0a | Event schema versioning + tolerant decode | `ClipboardModels.swift`, `ClipboardArchiveWriter.swift`, all readers | v1 lines decode as version 1; `archive-format.json` marker | old→new fixture decode, unknown-content-type skip, benchmark-schema drift guard | synthetic mixed-version archive read | integrated (`a77819a`) |
| 0b | Suppression unification + perf fixes (ledger cache, incremental retention prune, copy-back re-capture fix) | `ClipboardSuppression.swift` (new), `ClipboardArchiveReader/Searcher/Pruner/DerivedIndex`, `main.swift`, `ClipboardPanelController.swift` | none (behavior-preserving) | suppression parity tests, prune-increment tests, ledger-cache tests, timing bound | 50k synthetic scale benchmark (pending Slice 2 gate) | integrated (Slice 1 merge) |
| 0c | Synthetic fixture builders (every content type + migration path) | `Tests/.../SyntheticFixtures.swift` | n/a | fixture round-trips | n/a | integrated (`a77819a`) |
| 1 | Quick picker + configurable global shortcut | new `QuickPickerPanelController`, hotkey manager in MenuBar target; settings keys | settings keys default disabled | shortcut persistence, picker filter model | isolated AppKit gesture: open, arrow-navigate, copy-back, dismiss; <100 ms @50k | planned |
| 2 | Full-archive search + filters (date/app/type/window) | `ClipboardDerivedIndex` structured search, `ClipboardPanelController` archive mode | index `user_version` bump + rebuild | structured-search tests, filter tests | synthetic archive-wide search in isolated app | planned |
| 3 | Pins/favorites with retention protection | annotations store (new `ClipboardAnnotations.swift`), pruner exemption, panel UI | new sidecar file, absent = none | pin round-trip, prune-exemption, bulk-exemption | isolated app pin → prune → survives | planned |
| 4 | Duplicate grouping (count, first/last, expand) | `content_hash` index column, panel grouping | index version bump | grouping unit tests | isolated app with seeded duplicates | planned |
| 5 | Bulk management (selection/date/app/type/sensitivity) + truthful reclaim preview | bulk engine over redactor, panel multi-select UI, dry-run preview | none | dry-run == execute parity, count/byte truth tests | synthetic bulk delete with before/after receipts | planned |
| 6 | Rich formats (image/file/RTF/color/link) | capture branch in `main.swift`, writer/reader body types, detail rendering | event schema v2 fields, tolerant decode | per-type round-trip, size-cap block, containment | isolated capture of synthetic rich pasteboard | planned |
| 7 | Clip actions (plain copy, strip formatting, URL cleanup, whitespace, join, edit-before-copy) | new `ClipTransformations.swift` (core), panel/picker actions | none | pure-function transform tests (fixture table) | isolated app action gestures | planned |
| 8 | Tags, collections, snippets | annotations store, panel UI, picker sections | sidecar versioned | tag/collection/snippet round-trips | isolated app tagging flow | planned |
| 9 | Privacy upgrades (per-app rules, manual sensitivity, expiring clips, timed private mode, blocked-event explanations) | `ClipboardPrivacyFilter`, settings rules, annotations expiry, menu UI | settings keys default to current behavior | allowed/blocked/false-positive/non-retention fixtures per rule | isolated rule exercise | planned |
| 10 | Storage/health dashboard (sizes, counts, repair, cleanup) | `ClipboardArchiveHealth` extensions, new settings card | none | health computation tests | isolated dashboard render | planned |
| 11 | Encrypted backup/export + restore/import | new `ClipboardBackup.swift` (CryptoKit AES-GCM + KDF), settings entry, CLI cmds | backup format v1, versioned header | round-trip, wrong-passphrase, tamper, partial-restore tests | synthetic export→wipe→import in isolated root | planned |
| 12 | Daily-use polish (shortcut config UI, launch-at-login via SMAppService, states, onboarding, version/update info) | Settings/onboarding controllers, `SMAppService` integration | settings keys | login-item state tests where feasible | isolated render QA + keyboard-only walkthrough | planned |

## Integration checkpoints

| Date | Commit | Contents | Gate receipts |
|------|--------|----------|---------------|
| 2026-07-30 | `43ab766` (baseline) | pre-expansion baseline | 28/28 tests, 25 checks ok, package+validate+local-only+rollback ok |
| 2026-07-30 | Slice 1 (`a77819a` + perf merge) | schema versioning, tolerant content types, fixtures, `--index-path`, suppression unification, ledger cache, incremental retention, copy-back re-capture fix | 41/41 tests (3 suites), 28 checks ok, package+validate+local-only+rollback ok |

## Discovered issues (running log)

| Found | Issue | Disposition |
|-------|-------|-------------|
| 2026-07-30 scout | Retention prune = full rewrite + full FTS rebuild on every capture in recent-10/50 | fix in Slice 1 (contract 9) |
| 2026-07-30 scout | Panel copy-back re-captures the copied clip as a new event | fix in Slice 1 (contract 2) |
| 2026-07-30 scout | Suppression checks inconsistent across readers (ledger vs doNotIndex) | unify in Slice 1 (contract 6) |
| 2026-07-30 scout | History search is preview-only, never searches body text or FTS | addressed by Slice 3 |
| 2026-07-30 scout | `uiVisibleUntil` written but never read | keep writing (compat), document as legacy |
| 2026-07-30 scout | CLI has no `--index-path` flag; prune/redact use default index with custom `--archive-root` | fix in Slice 1 |
| 2026-07-30 scout | `check-local-only.sh` does not scan `Sources/ClipboardArchiveChecks` | fix in Slice 1 |
| 2026-07-30 scout | `scale-benchmark.sh` duplicates event schema by hand | drift guard in Slice 1 |
| 2026-07-30 scout | NDJSON appends unprotected between app and CLI monitor running concurrently | document; single-writer guidance; ledger/index already locked |
