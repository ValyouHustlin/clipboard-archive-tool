# Clipboard Archive Complete Feature Expansion — Lead Handoff

## GOAL

Turn Clipboard Archive into a production-tested, keyboard-first local clipboard
application containing every feature Aaron approved below. Done means all
features are coherently integrated, backward-compatible, documented, tested
against synthetic fixtures, packaged successfully, and usable as one product
rather than twelve disconnected additions.

Why: Aaron wants the current polished local utility developed into the complete
version he would personally want to use, while keeping it open source rather
than pursuing a paid-product or App Store program.

The lead owns the full outcome and continues until every acceptance item is
complete or an Aaron-gated operation is the only remaining step. It must use
background sub-agents throughout the build to keep its own context focused on
architecture, sequencing, integration, and product quality. Every substantial
implementation epic, independent audit, and verification pass should have a
bounded sub-agent brief. Parallel code-writing agents work in isolated
worktrees/branches; read-only reviewers may share the integration checkout.
The lead integrates and owns all final decisions.

VERIFICATION: The baseline executable check is
`/usr/bin/xcrun swift test`; the complete checkpoint gate is specified below.

### Required feature set

1. A configurable global-shortcut quick picker with keyboard navigation,
   search, copy-back, and clean dismissal. Direct paste may be optional and
   permission-gated; copy-back must work without Accessibility permission.
2. Full-archive UI search using the derived index, with date, source-app,
   content-type, and working-window filters. The existing limited History
   search remains fast and understandable.
3. Pins/favorites protected from ordinary cleanup, with clear retention
   semantics.
4. Bulk management by selection, date, source app, type, and sensitivity,
   including truthful reclaimed-space previews and confirmation/undo or
   tombstone-safe behavior.
5. Duplicate grouping with occurrence count, first/last copied times, and a
   deliberate expand path.
6. Rich clipboard formats: images, files, rich text, colors, and formatted
   links, with schema versioning and backward compatibility for the existing
   text archive.
7. Clip actions: plain-text copy, formatting removal, URL tracking cleanup,
   whitespace normalization, selected-clip joining, and edit-before-copy.
8. Tags, collections, and reusable snippets without forcing organization on
   ordinary capture.
9. Stronger privacy controls: per-app rules, manual sensitivity, expiring
   sensitive clips, timed private mode, and understandable blocked-event
   explanations.
10. A Settings storage/health dashboard with archive/index sizes and counts,
    repair/rebuild controls, and safe cleanup entry points.
11. Local encrypted backup/export and restore/import using vetted platform
    cryptography and a real KDF; never invent cryptography and never move data
    automatically.
12. Daily-use polish: configurable shortcuts, launch-at-login control,
    density/appearance QA, excellent empty/error/loading states, onboarding
    updates, version information, and update availability through the existing
    human-run release/update path. Preserve offline app runtime unless Aaron
    explicitly approves changing that promise.

## SEQUENCE

1. Re-read the governing files listed below, inspect HEAD, current tests, data
   model, and UI. Create a durable feature matrix mapping each item above to
   source surfaces, migrations, tests, runtime verification, docs, and status.
2. Establish cross-cutting contracts before fan-out: versioned archive schema,
   derived-index evolution, settings migration, item identity, pin/tag/rule
   persistence, rich-content containment, undo/deletion semantics, and global
   shortcut ownership. Add synthetic fixture builders that cover every content
   type and migration path.
3. Deliver vertical slices in dependency order:
   - foundation/data migrations and synthetic fixture infrastructure;
   - quick picker and shortcut configuration;
   - full-archive search and advanced filters;
   - pin/tag/collection/duplicate model and UI;
   - bulk management, privacy rules, retention, and dashboard;
   - rich content capture/storage/rendering;
   - transformations and edit-before-copy;
   - encrypted export/import and recovery;
   - onboarding, launch-at-login, update path, accessibility, and final polish.
   Independent discovery, design, and test-harness work may run in parallel.
4. After each slice, integrate immediately, run the full suite, exercise the
   actual synthetic runtime flow, update the feature matrix/docs, and commit a
   coherent checkpoint. Do not leave a long-lived integration pile.
5. Run independent first-pass and privacy/security reviews on every
   persistence or deletion change. After two failed corrections on one issue,
   recycle that subtask into fresh context with a distilled brief.
6. Finish with a whole-product verification pass, clean-room install/update/
   rollback exercise, accessibility and keyboard-only walkthrough, scale and
   failure testing, complete docs, clean tree, pushed commits, and green CI.
   Build the final installable artifact, but do not replace Aaron's live app
   without a fresh explicit approval.

Smallest useful read order:

1. `/Users/legacy/AGENTS.md`
2. `/Users/legacy/Development/AGENTS.md`
3. this repository's `AGENTS.md`
4. `/Users/legacy/Development/AI/docs/agent-os.md`
5. `/Users/legacy/Development/AI/docs/lane-lifecycle-contract.md`
6. `README.md`
7. `docs/architecture.md`
8. `docs/production-readiness-review.md`
9. `Sources/ClipboardArchiveCore/ClipboardSettings.swift`
10. `Sources/ClipboardArchiveMenuBar/ClipboardPanelController.swift`
11. `Sources/ClipboardArchiveMenuBar/ClipboardSettingsWindowController.swift`
12. the archive/index/privacy/capture types and current tests as routed by
    source references.

## GOTCHAS

The real archive is private and out of bounds. Never read, print, grep, search,
sample, summarize, export, screenshot, or copy any live clipboard record. Never
open live History. Work only from schema, counts, file metadata, and synthetic
fixtures authored by the lane. Do not put archive or export contents into
prompts, sub-agent contexts, logs, tests, reports, or commits. If any content is
incidentally seen, surface that fact without repeating it.

The installed app is live daily infrastructure. At handoff time PID `10609`
runs `dist/ClipboardArchive.app`; it contains the UI build but not HEAD's new
automatic legacy-settings permission migration. Do not stop, replace, or fight
it. Development instances require isolated `/tmp` archive, index, Application
Support, preferences, and instance-lock roots, with capture explicitly off
unless a synthetic-capture test is the scoped action.

Rich formats, deletion, retention, and backup all touch the privacy boundary.
Maintain path containment, owner-only permissions, plaintext disclosure where
applicable, backward compatibility, and fail-closed behavior. Never test
destructive behavior against the real archive. Use vetted cryptography and
versioned synthetic compatibility fixtures.

The app's current promise is offline runtime. “Update availability” must use
the existing human-run updater/release flow or another no-background-network
design unless Aaron approves a promise change.

## OWNER + AUTONOMY

The fresh lead is the single owner and integration authority. It may create
branches/worktrees, delegate to background sub-agents, edit code/tests/docs,
refactor, build, package, commit, push to Aaron's repository, and run isolated
synthetic app instances. It should batch work and decisions rather than ask
Aaron feature-by-feature.

Ask Aaron before any live-app replacement or stop, real archive mutation or
movement, public/GitHub release publication, App Store step, code-signing
identity decision, paid service/spend, pricing decision, new cloud/network
behavior, or irreversible external action. Public open-source source pushes are
already authorized; publishing a release artifact to users is still gated.

Sub-agents are not mini-leads. Give each one a concrete bounded artifact,
explicit file/worktree ownership, synthetic verification command, and return
contract. The lead keeps the feature matrix, architecture, dependency order,
integration branch, and done-bar. No sibling tmux windows for sub-work; use
background agents or the canonical headless model wrappers inside this lane.

## VERIFICATION

The minimum executable gate after every integration checkpoint is:

```bash
/usr/bin/xcrun swift test
/usr/bin/xcrun swift run clipboard-archive-checks
./scripts/package-release.sh
./scripts/validate-release.sh releases/ClipboardArchive-0.1.2-macos-arm64
./scripts/check-local-only.sh releases/ClipboardArchive-0.1.2-macos-arm64
./scripts/test-install-rollback.sh releases/ClipboardArchive-0.1.2-macos-arm64
```

Add and run feature-specific executable checks rather than relying only on the
commands above. Every UI feature requires an isolated synthetic AppKit gesture
and visual inspection. Every migration requires old→new and failure-preserving
fixtures. Every destructive feature requires dry-run/count evidence plus
synthetic deletion/restore verification. Every privacy rule requires allowed,
blocked, false-positive, and non-retention fixtures. Full-archive search,
duplicates, tags, pins, rich types, transformations, and encrypted backup/
restore each require round-trip tests and actual synthetic runtime observation.
Run scale benchmarks for realistic large histories and verify that the quick
picker remains responsive.

Current verified baseline at 2026-07-30 09:57 MST:

- branch `main`, clean tree, HEAD `64ff344`;
- local and GitHub CI pass 28 Swift tests, core checks, packaging, validation,
  local-only boundary, and failed-update rollback;
- live PID `10609` runs the prior installed binary hash
  `75e26f065aa10d6bbb44ee2dbbc8d8527593483a99b557a0eb8235fe849d32d8`;
- the HEAD release artifact hash is
  `1637b996bd9e5dc8efbad167aef551c493f61cc98f13cd10e7abfd24aaa9e040`;
- Aaron's settings file is already owner-only `0600`;
- no real archive content was read to establish this baseline.

## CLAIM DISCIPLINE

Assert only from output or behavior observed in the current lane. A passing
build is not UI verification; a test is not a real-flow observation; a package
is not an installed app. State synthetic fixtures explicitly. Preserve exact
commands and relevant output. Report unverified behavior and residual risk
plainly rather than rounding either up to success.

## OUTPUT CONTRACT

Maintain the feature matrix and architecture in the repository throughout.
Surface to Aaron only for a blocker/approval gate or one dense milestone report;
do not spend his prompts on routine progress. Every milestone report must state:
features completed, integrated commit(s), exact verification receipt, discovered
issues added/fixed, remaining feature matrix, and any gated decision with one
recommended default.

Final closeout must be under 40 lines and include:

1. product outcome and the complete feature checklist;
2. commits/branch/CI and clean-tree evidence;
3. exact test/check/package/runtime receipts;
4. synthetic-only privacy statement;
5. installed-vs-built state and any Aaron-gated final action;
6. discovered issues and durable fixes;
7. one recommended `[f]` action if a human gate remains.

Findings and decisions must be in the message body, not only in files. Aaron
terminal replies follow `/Users/legacy/CLAUDE.md` FIRST-REPLY CONTRACT and the
terminal comms rules. Do not declare completion while any required feature,
verification gate, documentation update, integration cleanup, or discovered
in-scope issue remains.

You operate under the Lane Lifecycle Contract:
`/Users/legacy/Development/AI/docs/lane-lifecycle-contract.md`.
