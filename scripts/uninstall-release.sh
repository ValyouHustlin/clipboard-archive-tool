#!/usr/bin/env bash
set -euo pipefail

LABEL="app.clipboardarchive"
APP_TARGET="${CLIPBOARD_ARCHIVE_APP_PATH:-$HOME/Applications/ClipboardArchive.app}"
BIN_DIR="${CLIPBOARD_ARCHIVE_BIN_DIR:-$HOME/.local/bin}"
PLIST="$HOME/Library/LaunchAgents/${LABEL}.plist"

if launchctl print "gui/$(id -u)/$LABEL" >/dev/null 2>&1; then
  launchctl bootout "gui/$(id -u)" "$PLIST" >/dev/null 2>&1 || true
fi
pkill -x ClipboardArchive >/dev/null 2>&1 || true

rm -f "$PLIST"
rm -rf "$APP_TARGET"
rm -f "$BIN_DIR/clipboard-archive"

echo "removed_app: $APP_TARGET"
echo "removed_cli: $BIN_DIR/clipboard-archive"
echo "removed_launch_agent: $PLIST"
echo "archive data was left in place"
