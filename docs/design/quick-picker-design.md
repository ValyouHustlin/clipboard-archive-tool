# Quick Picker + Global Shortcut — Implementation Design

Status: approved by lead 2026-07-30. Implements contract 8 of
`docs/expansion-contracts.md` (feature matrix row 1). The Slice 2
implementation agent builds exactly this; deviations go back to the lead.

## Architecture

- **Hotkey**: `@MainActor GlobalHotKeyManager` (MenuBar target) wrapping
  Carbon `RegisterEventHotKey`/`InstallEventHandler`. Owned by
  `ClipboardMenuBarApp`. No Accessibility permission, no CGEvent tap.
- **Picker**: `QuickPickerPanelController` owning a `QuickPickerPanel:
  NSPanel` (`.nonactivatingPanel`, floating, `canBecomeKey` override). The
  frontmost app stays active throughout — that is what makes copy-back and
  direct paste land in the right place.
- **Filtering**: pure AppKit-free `ClipboardQuickPickerFilter` in Core
  (unit-testable). Same matching semantics as the History window filter
  (lowercased substring over preview + app name + type rawValue).
  Preview-only search is intentional; FTS search is Slice 3.
- **Copy-back**: the picker never touches `NSPasteboard` itself; it calls an
  injected closure backed by the app delegate's shared `copyToPasteboard`
  helper (Slice 1B) which updates `lastChangeCount`/`lastContentHash`.
- **Settings**: new keys in `settings.json`, tolerant decode, defaults off.
- **Direct paste**: opt-in; gated at use time on `AXIsProcessTrusted()`;
  degrades to copy-back silently.

## Settings shape (Core)

```json
"shortcuts": {
  "quickPicker": { "enabled": false, "keyCode": 9, "modifiers": ["option", "command"] }
},
"quickPickerDirectPasteEnabled": false
```

- `ClipboardShortcutSetting { enabled: Bool, keyCode: Int, modifiers: [String] }`
  with `quickPickerDefault` (⌥⌘V, disabled), `carbonModifierFlags: UInt32`
  (command=0x0100, shift=0x0200, option=0x0800, control=0x1000),
  `isValid` (requires ≥1 of ⌘/⌥/⌃; shift-only rejected), `displayString`
  (kVK table; unknown → "Key <n>"). Unknown modifier strings dropped on
  decode.
- `ClipboardSettings.shortcuts: [String: ClipboardShortcutSetting]`
  (decodeIfPresent ?? [:]) + `quickPickerShortcut` accessor +
  `quickPickerDirectPasteEnabled: Bool` (?? false). Dictionary-keyed by
  action id so future shortcuts need no migration.

## GlobalHotKeyManager (Carbon sketch)

- `register(id:keyCode:carbonModifiers:) -> RegistrationResult`
  (`registered | conflict(OSStatus) | failed(OSStatus)`;
  `eventHotKeyExistsErr == -9878`). `EventHotKeyID(signature: 'CLAR', id:)`,
  `GetApplicationEventTarget()`.
- Handler installed once via `InstallEventHandler` for
  `kEventClassKeyboard/kEventHotKeyPressed`; extracts `EventHotKeyID` with
  `GetEventParameter`; app-target Carbon events arrive on the main thread →
  `MainActor.assumeIsolated { manager.onHotKey?(id) }`.
  `Unmanaged.passUnretained(self)` is safe (app-lifetime object).
- Registration failure surfaces in Settings (red label) + menu `lastStatus`;
  shortcut stays saved but reported "not active". No `fn` modifier support
  (Carbon limitation) — recorder must not offer it.

## QuickPickerPanel + controller

Panel (load-bearing details):
- `override var canBecomeKey: Bool { true }` (borderless panels refuse key
  otherwise), `canBecomeMain: false`.
- styleMask `[.nonactivatingPanel, .borderless]`; `isFloatingPanel`,
  `.floating` level, `hidesOnDeactivate = false`, collectionBehavior
  `[.canJoinAllSpaces, .fullScreenAuxiliary]`, `animationBehavior =
  .utilityWindow`. `makeKeyAndOrderFront(nil)` WITHOUT `NSApp.activate`.

Controller: `Dependencies { loadEvents, copyToPasteboard, directPasteAllowed,
performDirectPaste }`; `toggle()` / `present()` (reload, clear query, select
row 0, center on `NSScreen.main` top third, ~640×420) / `dismiss()`.
UI: plain `NSTextField` search (NOT `NSSearchField` — it eats Escape) +
single-column NSTableView (~44pt rows, reuse History cell style) + footer
hint `"↩ copy  ⌘↩ paste  esc close"` (⌘↩ shown only when direct paste
enabled+trusted).

Keyboard routing — all typing goes to the window field editor; intercept via
`NSControlTextEditingDelegate control(_:textView:doCommandBy:)`:
`moveUp/moveDown` → selection (clamped), `insertNewline` → commit,
`cancelOperation` → dismiss, `insertTab` → swallow. ⌘↩ never reaches
`doCommandBy`: override `performKeyEquivalent` in the panel (keyCode 36 +
.command → commit with direct paste). `controlTextDidChange` → filter →
reload → select row 0. Double-click commits.

Dismissal: Esc; `NSWindow.didResignKeyNotification` (click-away) guarded by
an `isCommitting` flag; hotkey toggles.

Commit sequence: set `isCommitting` → `copyToPasteboard(event)` (BEFORE
teardown) → `dismiss()` → if direct paste allowed:
`asyncAfter(.now() + 0.08) { performDirectPaste() }` (lets the panel resign
key so ⌘V lands in the user's app). On copy failure keep panel open with
inline status.

Direct paste (app delegate): re-check
`settings.quickPickerDirectPasteEnabled && AXIsProcessTrusted()` every call;
CGEvent keyDown/keyUp virtualKey 9 with `.maskCommand` posted to
`.cghidEventTap`. Failure mode is always copy-back, never a dialog.

## ShortcutRecorderView

Button-like NSView showing `displayString` / "Record Shortcut". Recording
uses `NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged])`
(sees keys before key-equivalents; no field-editor issues); Esc cancels,
Delete clears (enabled=false), invalid combos shake/beep. Monitor removed on
every exit path + `windowWillClose` safety net. While recording, the app
delegate suspends live registration (new delegate methods
`willBegin/didEndShortcutRecording`) so pressing the current combo doesn't
trigger the picker. Accessibility label "Quick picker shortcut".

## Settings window card

New "Shortcuts" card (existing `sectionCard` builder, symbol `keyboard`,
tint `.systemOrange`), right column above Local Storage: enable checkbox,
recorder row, direct-paste checkbox with live permission status line
("Accessibility access granted" / "Requires Accessibility access —
copy-back is used until granted" + "Open System Settings" button via
`x-apple.systempreference:com.apple.preference.security?Privacy_Accessibility`).
`AXIsProcessTrustedWithOptions(prompt: true)` fires ONLY when the user first
checks the box — never from the picker at paste time. Red conflict label,
`showShortcutRegistrationFailure(_:)` API.

## App delegate wiring

- `hotKeyManager.onHotKey` → `toggleQuickPicker()`;
  `applyQuickPickerShortcut()` on launch and after settings save
  (unregister → guard enabled+valid → register → surface failure).
- Menu item "Quick Picker" so the feature is reachable without a shortcut.
- Cache: `quickPickerCache` + `quickPickerCacheDirty` flag set at every
  archive mutation (store, delete, prune, settings save). Loader uses
  `reader.recentItems(since: historyWindow, limit: recentItemLimit)`.
  <100 ms at 50k relies on `recentItems` early-exit + Slice 1B ledger cache;
  warm repeat opens are O(1). Benchmark receipt gates the slice.

## DEBUG harness extension

`CLIPBOARD_ARCHIVE_UI_AUTOMATION_SCREEN=quickpicker` (keep /tmp guard):
- Automation mode NEVER registers the Carbon hotkey (a dev instance must not
  grab system combos while the live app runs); entry is `toggleQuickPicker()`
  — the same method the hotkey invokes.
- Pasteboard isolation: automation uses a private
  `NSPasteboard(name: "app.clipboardarchive.ui-automation")` override in
  `copyToPasteboard` so gestures never clobber the real clipboard.
- Env: reuse `..._QUERY`; new `..._GESTURES` (comma list `down,up,return,
  escape` → same handlers as doCommandBy); new `..._RESULT_PATH` → JSON
  `{filteredCount, selectedPreviewPrefix, pasteboardMatchesSelection,
  pickerVisibleAfterGestures, openElapsedMilliseconds, eventCountBefore,
  eventCountAfter}`.
- Matrix (separate launches, all /tmp roots): (1) render PNG; (2) QUERY
  filtered PNG; (3) GESTURES=down,down,return JSON incl. no-re-capture
  receipt (one variant with archiveEnabled=true + a poll tick asserting
  event count unchanged); (4) GESTURES=escape JSON (pasteboard untouched).

## Test plan

Unit (new files under Tests/AIHubClipboardCoreTests/): shortcut setting
(defaults, carbon flags exact values ⌥⌘=2304 ⌃⇧=0x1200, isValid, unknown
modifier drop, displayString table); settings migration fixtures (current
shape → disabled defaults; future unknown action id loads; round-trip);
filter semantics; store round-trip via atomic path.
Harness/manual: registration+conflict, key routing (gesture matrix),
focus-loss dismissal, direct paste with/without trust.
Benchmark: 50k synthetic archive, `openElapsedMilliseconds < 100`.

## Risks (top)

1. Borderless panel refusing key → mandatory `canBecomeKey` override;
   harness variant 2 is the regression guard.
2. Field editor eats keys → doCommandBy interception; plain NSTextField.
3. Hotkey conflict → surfaced, saved-but-inert, recorder suspend/resume.
4. Re-capture loop → picker has zero pasteboard access; shared helper only;
   harness variant 3 receipt.
5. Dev instance stealing real shortcut → default disabled; automation never
   registers.

## Implementation order

1. Core: shortcut setting + settings keys + filter + unit tests.
2. GlobalHotKeyManager + delegate wiring + menu item.
3. QuickPickerPanelController + copyToPasteboard injection.
4. ShortcutRecorderView + Settings card + conflict surfacing.
5. Direct-paste path.
6. Harness extension + gesture/JSON variants + benchmark receipt.
