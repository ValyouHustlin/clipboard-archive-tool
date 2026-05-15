#!/usr/bin/env bash
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_SOURCE="${HERE}/ClipboardArchive.app"
CLI_SOURCE="${HERE}/bin/clipboard-archive"
LABEL="app.clipboardarchive"
APP_DIR="${CLIPBOARD_ARCHIVE_APP_DIR:-$HOME/Applications}"
APP_TARGET="$APP_DIR/ClipboardArchive.app"
BIN_DIR="${CLIPBOARD_ARCHIVE_BIN_DIR:-$HOME/.local/bin}"
ARCHIVE_ROOT="${CLIPBOARD_ARCHIVE_ARCHIVE_ROOT:-$HOME/Library/Application Support/ClipboardArchive/Archive/clipboard-history}"
INDEX_PATH="${CLIPBOARD_ARCHIVE_INDEX_PATH:-$HOME/Library/Application Support/ClipboardArchive/Indexes/clipboard-search.sqlite}"
PLIST="$HOME/Library/LaunchAgents/${LABEL}.plist"
LOG_DIR="$HOME/Library/Logs/ClipboardArchive"

usage() {
  cat <<'USAGE'
Install or update Clipboard Archive.

Environment overrides:
  CLIPBOARD_ARCHIVE_APP_DIR       Default: ~/Applications
  CLIPBOARD_ARCHIVE_BIN_DIR       Default: ~/.local/bin
  CLIPBOARD_ARCHIVE_ARCHIVE_ROOT  Default: ~/Library/Application Support/ClipboardArchive/Archive/clipboard-history
  CLIPBOARD_ARCHIVE_INDEX_PATH    Default: ~/Library/Application Support/ClipboardArchive/Indexes/clipboard-search.sqlite

Examples:
  ./install.sh
  CLIPBOARD_ARCHIVE_APP_DIR=/Applications ./install.sh
USAGE
}

if [ "${1:-}" = "--help" ]; then
  usage
  exit 0
fi

if [ ! -d "$APP_SOURCE" ]; then
  echo "missing app bundle: $APP_SOURCE" >&2
  exit 1
fi

mkdir -p "$APP_DIR" "$BIN_DIR" "$(dirname "$ARCHIVE_ROOT")" "$(dirname "$INDEX_PATH")" "$HOME/Library/LaunchAgents" "$LOG_DIR"

if launchctl print "gui/$(id -u)/$LABEL" >/dev/null 2>&1; then
  launchctl bootout "gui/$(id -u)" "$PLIST" >/dev/null 2>&1 || true
fi
pkill -x ClipboardArchive >/dev/null 2>&1 || true

rm -rf "$APP_TARGET"
cp -R "$APP_SOURCE" "$APP_TARGET"
xattr -dr com.apple.quarantine "$APP_TARGET" >/dev/null 2>&1 || true

if [ -x "$CLI_SOURCE" ]; then
  cp "$CLI_SOURCE" "$BIN_DIR/clipboard-archive"
  chmod +x "$BIN_DIR/clipboard-archive"
fi

cat > "$PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
 "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>$LABEL</string>
  <key>ProgramArguments</key>
  <array>
    <string>/usr/bin/open</string>
    <string>$APP_TARGET</string>
  </array>
  <key>RunAtLoad</key>
  <true/>
  <key>KeepAlive</key>
  <false/>
  <key>EnvironmentVariables</key>
  <dict>
    <key>CLIPBOARD_ARCHIVE_ARCHIVE_ROOT</key>
    <string>$ARCHIVE_ROOT</string>
    <key>CLIPBOARD_ARCHIVE_INDEX_PATH</key>
    <string>$INDEX_PATH</string>
  </dict>
  <key>StandardOutPath</key>
  <string>$LOG_DIR/launchagent.out.log</string>
  <key>StandardErrorPath</key>
  <string>$LOG_DIR/launchagent.err.log</string>
</dict>
</plist>
PLIST

plutil -lint "$PLIST" >/dev/null
launchctl bootstrap "gui/$(id -u)" "$PLIST"
launchctl kickstart -k "gui/$(id -u)/$LABEL" >/dev/null 2>&1 || true

echo "installed_app: $APP_TARGET"
echo "installed_cli: $BIN_DIR/clipboard-archive"
echo "launch_agent: $PLIST"
echo "archive_root: $ARCHIVE_ROOT"
echo "index_path: $INDEX_PATH"
