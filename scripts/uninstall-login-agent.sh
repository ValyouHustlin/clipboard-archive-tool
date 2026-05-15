#!/usr/bin/env bash
set -euo pipefail

LABEL="app.clipboardarchive"
PLIST="$HOME/Library/LaunchAgents/${LABEL}.plist"

if [ -f "$PLIST" ]; then
  launchctl bootout "gui/$(id -u)" "$PLIST" >/dev/null 2>&1 || true
  rm -f "$PLIST"
fi

pkill -x ClipboardArchive >/dev/null 2>&1 || true
pkill -x ClipboardArchive >/dev/null 2>&1 || true
echo "uninstalled $LABEL"
