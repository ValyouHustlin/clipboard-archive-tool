#!/usr/bin/env bash
# What's New harness runner (development receipts only). Renders the
# post-upgrade "What's New" window in BOTH light and dark appearance, plus a
# gesture variant proving the show → persist → never-again contract, against
# ISOLATED /tmp roots — never the live archive, never the real clipboard,
# never the installed app.
set -euo pipefail
export PATH="/usr/bin:/bin:/usr/sbin:/sbin:${PATH:-}"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BINARY="$ROOT/.build/debug/ClipboardArchiveMenuBar"
OUT_BASE="/tmp"

run_case() {
  local name="$1"
  shift
  local dir="$OUT_BASE/clipboard-whatsnew-$name"
  rm -rf "$dir"
  mkdir -p "$dir/archive" "$dir/support"
  CLIPBOARD_ARCHIVE_ARCHIVE_ROOT="$dir/archive" \
  CLIPBOARD_ARCHIVE_INDEX_PATH="$dir/archive/index.sqlite" \
  CLIPBOARD_ARCHIVE_APPLICATION_SUPPORT_ROOT="$dir/support" \
  CLIPBOARD_ARCHIVE_UI_SNAPSHOT_PATH="$dir/snapshot.png" \
  CLIPBOARD_ARCHIVE_UI_AUTOMATION_RESULT_PATH="$dir/result.json" \
  CLIPBOARD_ARCHIVE_UI_AUTOMATION_SCREEN=whatsnew \
  "$@" \
  "$BINARY" >/dev/null 2>&1 || true
  if [ -f "$dir/snapshot.png" ]; then
    echo "$name: snapshot ok ($(stat -f %z "$dir/snapshot.png") bytes) -> $dir/snapshot.png"
  else
    echo "$name: NO SNAPSHOT"
  fi
  if [ -f "$dir/result.json" ]; then
    echo "$name: result -> $dir/result.json"
  fi
}

for mode in light dark; do
  run_case "$mode" env CLIPBOARD_ARCHIVE_UI_AUTOMATION_APPEARANCE="$mode"
done
# Gesture variant: Done dismisses; the receipt proves the persisted
# lastSeenAppVersion and a false second-launch decision.
run_case "persist" \
  env CLIPBOARD_ARCHIVE_UI_AUTOMATION_APPEARANCE=light \
      CLIPBOARD_ARCHIVE_UI_AUTOMATION_GESTURES=done
