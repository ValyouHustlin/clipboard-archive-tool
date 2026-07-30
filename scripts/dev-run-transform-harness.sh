#!/usr/bin/env bash
# Slice 7 clip-actions harness runner (development receipts only).
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
  local dir="$OUT_BASE/clipboard-slice7-$name"
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

# h1 — Copy As Plain Text on a rich (RTF) clip: the pasteboard receives the
# stored plain fallback; event count and NDJSON bytes unchanged.
run_case "h1-copyas-plain-rtf" \
  env CLIPBOARD_ARCHIVE_UI_AUTOMATION_SCREEN=history \
      CLIPBOARD_ARCHIVE_UI_AUTOMATION_ARCHIVE_ENABLED=1 \
      CLIPBOARD_ARCHIVE_UI_AUTOMATION_SEED_RICH=1 \
      CLIPBOARD_ARCHIVE_UI_AUTOMATION_HISTORY_GESTURES="select-index:2,copy-as:plain"

# h2 — Copy As Cleaned Links on a clip whose URLs mix tracking + real
# params across two URLs with a fragment.
run_case "h2-copyas-cleanlinks" \
  env CLIPBOARD_ARCHIVE_UI_AUTOMATION_SCREEN=history \
      CLIPBOARD_ARCHIVE_UI_AUTOMATION_ARCHIVE_ENABLED=1 \
      CLIPBOARD_ARCHIVE_UI_AUTOMATION_SEED_TRACKING_URL=1 \
      CLIPBOARD_ARCHIVE_UI_AUTOMATION_HISTORY_GESTURES="select-first,copy-as:cleaned-links"

# h3 — Join Selected (comma-space) over a two-clip multi-selection.
run_case "h3-join-comma" \
  env CLIPBOARD_ARCHIVE_UI_AUTOMATION_SCREEN=history \
      CLIPBOARD_ARCHIVE_UI_AUTOMATION_ARCHIVE_ENABLED=1 \
      CLIPBOARD_ARCHIVE_UI_AUTOMATION_HISTORY_GESTURES="select-first-two,join-selected:comma-space"

# h4 — Edit Before Copy: production sheet, edited text committed through
# the production Copy button; archive bytes must stay identical.
run_case "h4-edit-before-copy" \
  env CLIPBOARD_ARCHIVE_UI_AUTOMATION_SCREEN=history \
      CLIPBOARD_ARCHIVE_UI_AUTOMATION_ARCHIVE_ENABLED=1 \
      CLIPBOARD_ARCHIVE_UI_AUTOMATION_HISTORY_GESTURES="select-first,edit-before-copy-commit"

# h5 — Quick picker ⌥↩ commits the RTF clip as PLAIN text (footer hint
# receipt included in the result JSON).
run_case "h5-picker-option-return" \
  env CLIPBOARD_ARCHIVE_UI_AUTOMATION_SCREEN=quickpicker \
      CLIPBOARD_ARCHIVE_UI_AUTOMATION_ARCHIVE_ENABLED=1 \
      CLIPBOARD_ARCHIVE_UI_AUTOMATION_SEED_RICH=1 \
      CLIPBOARD_ARCHIVE_UI_AUTOMATION_QUERY="bold" \
      CLIPBOARD_ARCHIVE_UI_AUTOMATION_GESTURES="option-return"

# h6 — hint negative case: plain-text selection shows NO ⌥↩ hint.
run_case "h6-picker-hint-plain" \
  env CLIPBOARD_ARCHIVE_UI_AUTOMATION_SCREEN=quickpicker \
      CLIPBOARD_ARCHIVE_UI_AUTOMATION_ARCHIVE_ENABLED=1

echo "transform harness complete"
