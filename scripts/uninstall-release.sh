#!/usr/bin/env bash
# Remove Clipboard Archive: the app wherever a release put it, the
# command-line tool and the login item. Clipboard history is left in place.
set -euo pipefail

LABEL="app.clipboardarchive"
# Overridable so a test never looks at the real /Applications.
SYSTEM_APP_DIR="${CLIPBOARD_ARCHIVE_SYSTEM_APP_DIR:-/Applications}"
USER_APP_DIR="$HOME/Applications"
BIN_DIR="${CLIPBOARD_ARCHIVE_BIN_DIR:-$HOME/.local/bin}"
PLIST="$HOME/Library/LaunchAgents/${LABEL}.plist"
LAUNCHCTL_BIN="${CLIPBOARD_ARCHIVE_LAUNCHCTL_BIN:-/bin/launchctl}"

if "$LAUNCHCTL_BIN" print "gui/$(id -u)/$LABEL" >/dev/null 2>&1; then
  "$LAUNCHCTL_BIN" bootout "gui/$(id -u)" "$PLIST" >/dev/null 2>&1 || true
fi

# Stop the copy that holds the archive lock, wherever it runs from.
LOCK_FILE="$HOME/Library/Application Support/ClipboardArchive/ClipboardArchive.lock"
if [ -f "$LOCK_FILE" ]; then
  running_pid="$(/usr/bin/tr -dc '0-9' < "$LOCK_FILE" || true)"
  if [ -n "$running_pid" ]; then
    running_command="$(/bin/ps -p "$running_pid" -o command= 2>/dev/null || true)"
    case "$running_command" in
      */Contents/MacOS/ClipboardArchive|*/Contents/MacOS/ClipboardArchive\ *)
        kill "$running_pid" >/dev/null 2>&1 || true
        ;;
    esac
  fi
fi

rm -f "$PLIST"

# The disk image and every release-folder installer, old and new.
removed_any=false
failed=false
for candidate in \
  "${CLIPBOARD_ARCHIVE_APP_PATH:-}" \
  "$SYSTEM_APP_DIR/Clipboard Archive.app" \
  "$SYSTEM_APP_DIR/ClipboardArchive.app" \
  "$USER_APP_DIR/Clipboard Archive.app" \
  "$USER_APP_DIR/ClipboardArchive.app"; do
  [ -n "$candidate" ] || continue
  [ -d "$candidate" ] || continue
  if rm -rf "$candidate" 2>/dev/null && [ ! -e "$candidate" ]; then
    echo "removed_app: $candidate"
    removed_any=true
  else
    echo "could not remove: $candidate" >&2
    failed=true
  fi
done
if [ "$removed_any" = false ] && [ "$failed" = false ]; then
  echo "removed_app: none found"
fi

rm -f "$BIN_DIR/clipboard-archive"

echo "removed_cli: $BIN_DIR/clipboard-archive"
echo "removed_launch_agent: $PLIST"
echo "archive data was left in place"
if [ "$failed" = true ]; then
  exit 1
fi
