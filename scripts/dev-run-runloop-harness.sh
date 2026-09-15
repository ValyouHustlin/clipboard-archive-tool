#!/usr/bin/env bash
# Run-loop mode receipt (development only). Answers, with a number, whether
# the capture poll keeps firing while the main run loop is in a mode other
# than `.default` — the state a tracking menu or a modal panel puts it in.
#
# Isolated /tmp roots, the private automation pasteboard, archiving off:
# nothing here reads or writes a real store or the real clipboard.
set -euo pipefail
export PATH="/usr/bin:/bin:/usr/sbin:/sbin:${PATH:-}"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BINARY="$ROOT/.build/debug/ClipboardArchiveMenuBar"
SECONDS_TO_RUN="${1:-2.0}"

run_mode() {
  local mode="$1"
  local dir="/tmp/clipboard-runloop-$mode"
  rm -rf "$dir"
  mkdir -p "$dir/archive" "$dir/support"
  CLIPBOARD_ARCHIVE_ARCHIVE_ROOT="$dir/archive" \
  CLIPBOARD_ARCHIVE_INDEX_PATH="$dir/archive/index.sqlite" \
  CLIPBOARD_ARCHIVE_APPLICATION_SUPPORT_ROOT="$dir/support" \
  CLIPBOARD_ARCHIVE_UI_AUTOMATION_RESULT_PATH="$dir/result.json" \
  CLIPBOARD_ARCHIVE_UI_AUTOMATION_SCREEN=runloopmodes \
  CLIPBOARD_ARCHIVE_UI_AUTOMATION_RUNLOOP_MODE="$mode" \
  CLIPBOARD_ARCHIVE_UI_AUTOMATION_RUNLOOP_SECONDS="$SECONDS_TO_RUN" \
  "$BINARY" >/dev/null 2>&1 || true
  if [ -f "$dir/result.json" ]; then
    echo "$mode: $(tr -d ' \n' <"$dir/result.json")"
  else
    echo "$mode: NO RECEIPT"
  fi
}

# `default` is the control: both modes should report roughly
# span / interval ticks. A timer installed in `.default` alone answers zero
# for eventTracking, which is the capture hole this exists to catch.
run_mode eventTracking
run_mode default
