#!/usr/bin/env bash
set -euo pipefail

LABEL="app.clipboardarchive"
PLIST="$HOME/Library/LaunchAgents/${LABEL}.plist"

if [ -f "$PLIST" ]; then
  echo "plist: $PLIST"
  plutil -lint "$PLIST"
else
  echo "plist: missing"
fi

launchctl print "gui/$(id -u)/$LABEL" 2>/dev/null | sed -n '1,80p' || echo "launchctl: not loaded"
pgrep -fl 'ClipboardArchive|ClipboardArchive' || true
