#!/usr/bin/env bash
# Slice 6 rich-format harness runner (development receipts only).
# Runs the DEBUG automation build against ISOLATED /tmp roots on the
# private automation pasteboard — never the live archive, never the real
# clipboard, never the installed app.
set -euo pipefail
export PATH="/usr/bin:/bin:/usr/sbin:/sbin:${PATH:-}"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BINARY="$ROOT/.build/debug/ClipboardArchiveMenuBar"
OUT_BASE="/tmp"

run_case() {
  local name="$1"
  shift
  local dir="$OUT_BASE/clipboard-slice6-$name"
  rm -rf "$dir"
  mkdir -p "$dir/archive" "$dir/support"
  CLIPBOARD_ARCHIVE_ARCHIVE_ROOT="$dir/archive" \
  CLIPBOARD_ARCHIVE_INDEX_PATH="$dir/archive/index.sqlite" \
  CLIPBOARD_ARCHIVE_APPLICATION_SUPPORT_ROOT="$dir/support" \
  CLIPBOARD_ARCHIVE_UI_SNAPSHOT_PATH="$dir/snapshot.png" \
  CLIPBOARD_ARCHIVE_UI_AUTOMATION_RESULT_PATH="$dir/result.json" \
  "$@" \
  "$BINARY" >/dev/null 2>&1 || true
  echo "== $name =="
  if [ -f "$dir/result.json" ]; then
    cat "$dir/result.json"
  else
    echo "(no result.json)"
  fi
  if [ -f "$dir/snapshot.png" ]; then
    echo "snapshot: $dir/snapshot.png ($(stat -f %z "$dir/snapshot.png") bytes)"
  fi
  echo
}

# Rich-capture matrix: one synthetic multi-representation item per kind.
for kind in image files rtf color link; do
  run_case "h1-capture-$kind" \
    env CLIPBOARD_ARCHIVE_UI_AUTOMATION_SCREEN=richcapture \
        CLIPBOARD_ARCHIVE_UI_AUTOMATION_RICH_CAPTURE="$kind"
done

# Cap-block variant: oversized image against the clamp-floor cap.
run_case "h2-capblock" \
  env CLIPBOARD_ARCHIVE_UI_AUTOMATION_SCREEN=richcapture \
      CLIPBOARD_ARCHIVE_UI_AUTOMATION_RICH_CAPTURE=image \
      CLIPBOARD_ARCHIVE_UI_AUTOMATION_RICH_CAP_BLOCK=1

# History renders: seeded per-kind rich fixtures; one detail render per kind.
index=0
for kind in image files rtf color link; do
  run_case "h3-history-$kind" \
    env CLIPBOARD_ARCHIVE_UI_AUTOMATION_SCREEN=history \
        CLIPBOARD_ARCHIVE_UI_AUTOMATION_ARCHIVE_ENABLED=1 \
        CLIPBOARD_ARCHIVE_UI_AUTOMATION_SEED_RICH=1 \
        CLIPBOARD_ARCHIVE_UI_AUTOMATION_HISTORY_GESTURES="select-index:$index"
  index=$((index + 1))
done

# Quick picker render over the same rich fixtures.
run_case "h4-picker" \
  env CLIPBOARD_ARCHIVE_UI_AUTOMATION_SCREEN=quickpicker \
      CLIPBOARD_ARCHIVE_UI_AUTOMATION_ARCHIVE_ENABLED=1 \
      CLIPBOARD_ARCHIVE_UI_AUTOMATION_SEED_RICH=1

echo "rich harness complete"
