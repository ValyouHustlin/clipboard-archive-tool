#!/usr/bin/env bash
# Slice 9 daily-use polish harness runner (development receipts only).
# Renders every major surface in BOTH light and dark appearance, plus the
# zero-clip empty states, against ISOLATED /tmp roots — never the live
# archive, never the real clipboard, never the installed app.
set -euo pipefail
export PATH="/usr/bin:/bin:/usr/sbin:/sbin:${PATH:-}"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BINARY="$ROOT/.build/debug/ClipboardArchiveMenuBar"
OUT_BASE="/tmp"

run_case() {
  local name="$1"
  shift
  local dir="$OUT_BASE/clipboard-slice9-$name"
  rm -rf "$dir"
  mkdir -p "$dir/archive" "$dir/support"
  CLIPBOARD_ARCHIVE_ARCHIVE_ROOT="$dir/archive" \
  CLIPBOARD_ARCHIVE_INDEX_PATH="$dir/archive/index.sqlite" \
  CLIPBOARD_ARCHIVE_APPLICATION_SUPPORT_ROOT="$dir/support" \
  CLIPBOARD_ARCHIVE_UI_SNAPSHOT_PATH="$dir/snapshot.png" \
  CLIPBOARD_ARCHIVE_UI_AUTOMATION_RESULT_PATH="$dir/result.json" \
  "$@" \
  "$BINARY" >/dev/null 2>&1 || true
  if [ -f "$dir/snapshot.png" ]; then
    echo "$name: snapshot ok ($(stat -f %z "$dir/snapshot.png") bytes) -> $dir/snapshot.png"
  else
    echo "$name: NO SNAPSHOT"
  fi
}

for mode in light dark; do
  run_case "history-$mode" \
    env CLIPBOARD_ARCHIVE_UI_AUTOMATION_SCREEN=history \
        CLIPBOARD_ARCHIVE_UI_AUTOMATION_ARCHIVE_ENABLED=1 \
        CLIPBOARD_ARCHIVE_UI_AUTOMATION_APPEARANCE="$mode" \
        CLIPBOARD_ARCHIVE_UI_AUTOMATION_HISTORY_GESTURES=select-first
  run_case "settings-$mode" \
    env CLIPBOARD_ARCHIVE_UI_AUTOMATION_SCREEN=settings \
        CLIPBOARD_ARCHIVE_UI_AUTOMATION_APPEARANCE="$mode"
  run_case "settings-tall-$mode" \
    env CLIPBOARD_ARCHIVE_UI_AUTOMATION_SCREEN=settings \
        CLIPBOARD_ARCHIVE_UI_AUTOMATION_TALL_WINDOW=1 \
        CLIPBOARD_ARCHIVE_UI_AUTOMATION_APPEARANCE="$mode"
  run_case "onboarding-$mode" \
    env CLIPBOARD_ARCHIVE_UI_AUTOMATION_SCREEN=onboarding \
        CLIPBOARD_ARCHIVE_UI_AUTOMATION_APPEARANCE="$mode"
  run_case "quickpicker-$mode" \
    env CLIPBOARD_ARCHIVE_UI_AUTOMATION_SCREEN=quickpicker \
        CLIPBOARD_ARCHIVE_UI_AUTOMATION_ARCHIVE_ENABLED=1 \
        CLIPBOARD_ARCHIVE_UI_AUTOMATION_APPEARANCE="$mode"
  run_case "dashboard-$mode" \
    env CLIPBOARD_ARCHIVE_UI_AUTOMATION_SCREEN=dashboard \
        CLIPBOARD_ARCHIVE_UI_AUTOMATION_APPEARANCE="$mode"
  run_case "bulk-$mode" \
    env CLIPBOARD_ARCHIVE_UI_AUTOMATION_SCREEN=bulk \
        CLIPBOARD_ARCHIVE_UI_AUTOMATION_APPEARANCE="$mode"
  # Empty-state receipts: zero clips; history additionally proves the
  # capture-off hint (archiveEnabled stays 0).
  run_case "history-empty-captureoff-$mode" \
    env CLIPBOARD_ARCHIVE_UI_AUTOMATION_SCREEN=history \
        CLIPBOARD_ARCHIVE_UI_AUTOMATION_SEED_NONE=1 \
        CLIPBOARD_ARCHIVE_UI_AUTOMATION_APPEARANCE="$mode"
  run_case "quickpicker-empty-$mode" \
    env CLIPBOARD_ARCHIVE_UI_AUTOMATION_SCREEN=quickpicker \
        CLIPBOARD_ARCHIVE_UI_AUTOMATION_SEED_NONE=1 \
        CLIPBOARD_ARCHIVE_UI_AUTOMATION_APPEARANCE="$mode"
done
