#!/usr/bin/env bash
set -euo pipefail
export PATH="/usr/bin:/bin:/usr/sbin:/sbin:${PATH:-}"

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_SOURCE="${HERE}/ClipboardArchive.app"
CLI_SOURCE="${HERE}/bin/clipboard-archive"
LABEL="app.clipboardarchive"
APP_DIR="${CLIPBOARD_ARCHIVE_APP_DIR:-$HOME/Applications}"
APP_TARGET="$APP_DIR/ClipboardArchive.app"
APP_STAGE="$APP_DIR/.ClipboardArchive.app.install-$$"
APP_BACKUP="$APP_DIR/.ClipboardArchive.app.backup-$$"
BIN_DIR="${CLIPBOARD_ARCHIVE_BIN_DIR:-$HOME/.local/bin}"
ARCHIVE_ROOT="${CLIPBOARD_ARCHIVE_ARCHIVE_ROOT:-$HOME/Library/Application Support/ClipboardArchive/Archive/clipboard-history}"
INDEX_PATH="${CLIPBOARD_ARCHIVE_INDEX_PATH:-$HOME/Library/Application Support/ClipboardArchive/Indexes/clipboard-search.sqlite}"
PLIST="$HOME/Library/LaunchAgents/${LABEL}.plist"
PLIST_BACKUP="$HOME/Library/LaunchAgents/.${LABEL}.plist.backup-$$"
LOG_DIR="$HOME/Library/Logs/ClipboardArchive"
LAUNCHCTL_BIN="${CLIPBOARD_ARCHIVE_LAUNCHCTL_BIN:-/bin/launchctl}"
PGREP_BIN="${CLIPBOARD_ARCHIVE_PGREP_BIN:-/usr/bin/pgrep}"

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
if [ ! -x "$APP_SOURCE/Contents/MacOS/ClipboardArchive" ]; then
  echo "missing app executable: $APP_SOURCE/Contents/MacOS/ClipboardArchive" >&2
  exit 1
fi
if [ -f "$HERE/SHA256SUMS" ]; then
  (
    cd "$HERE"
    /usr/bin/shasum -a 256 -c SHA256SUMS >/dev/null
  )
fi

mkdir -p "$APP_DIR" "$BIN_DIR" "$(dirname "$ARCHIVE_ROOT")" "$(dirname "$INDEX_PATH")" "$HOME/Library/LaunchAgents" "$LOG_DIR"

rm -rf "$APP_STAGE" "$APP_BACKUP"
rm -f "$PLIST_BACKUP"
cp -R "$APP_SOURCE" "$APP_STAGE"
had_existing_plist=false
if [ -f "$PLIST" ]; then
  cp "$PLIST" "$PLIST_BACKUP"
  had_existing_plist=true
fi

rollback_update() {
  "$LAUNCHCTL_BIN" bootout "gui/$(/usr/bin/id -u)" "$PLIST" >/dev/null 2>&1 || true
  rm -rf "$APP_STAGE" "$APP_TARGET" || true
  if [ -d "$APP_BACKUP" ]; then
    mv "$APP_BACKUP" "$APP_TARGET" || true
  fi
  if [ "$had_existing_plist" = true ]; then
    mv "$PLIST_BACKUP" "$PLIST" || true
    "$LAUNCHCTL_BIN" bootstrap "gui/$(/usr/bin/id -u)" "$PLIST" >/dev/null 2>&1 || true
    "$LAUNCHCTL_BIN" kickstart -k "gui/$(/usr/bin/id -u)/$LABEL" >/dev/null 2>&1 || true
  else
    rm -f "$PLIST" || true
  fi
}

trap rollback_update ERR

if "$LAUNCHCTL_BIN" print "gui/$(/usr/bin/id -u)/$LABEL" >/dev/null 2>&1; then
  "$LAUNCHCTL_BIN" bootout "gui/$(/usr/bin/id -u)" "$PLIST" >/dev/null 2>&1 || true
fi

LOCK_FILE="$HOME/Library/Application Support/ClipboardArchive/ClipboardArchive.lock"
if [ -f "$LOCK_FILE" ]; then
    running_pid="$(/usr/bin/tr -dc '0-9' < "$LOCK_FILE")"
  if [ -n "$running_pid" ]; then
    running_command="$(/bin/ps -p "$running_pid" -o command= 2>/dev/null || true)"
    case "$running_command" in
      "$APP_TARGET/Contents/MacOS/ClipboardArchive"*)
        kill "$running_pid" >/dev/null 2>&1 || true
        for _ in 1 2 3 4 5; do
          kill -0 "$running_pid" >/dev/null 2>&1 || break
          sleep 0.2
        done
        ;;
    esac
  fi
fi

if [ -d "$APP_TARGET" ]; then
  mv "$APP_TARGET" "$APP_BACKUP"
fi
mv "$APP_STAGE" "$APP_TARGET"

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
"$LAUNCHCTL_BIN" bootstrap "gui/$(/usr/bin/id -u)" "$PLIST"
"$LAUNCHCTL_BIN" kickstart -k "gui/$(/usr/bin/id -u)/$LABEL" >/dev/null 2>&1 || true
sleep 1

if ! "$PGREP_BIN" -f "^${APP_TARGET}/Contents/MacOS/ClipboardArchive$" >/dev/null 2>&1; then
  echo "new app did not stay running; restoring previous app" >&2
  rollback_update
  trap - ERR
  exit 1
fi

trap - ERR
rm -rf "$APP_BACKUP"
rm -f "$PLIST_BACKUP"

if [ -x "$CLI_SOURCE" ]; then
  cp "$CLI_SOURCE" "$BIN_DIR/clipboard-archive"
  chmod +x "$BIN_DIR/clipboard-archive"
fi

echo "installed_app: $APP_TARGET"
echo "installed_cli: $BIN_DIR/clipboard-archive"
echo "launch_agent: $PLIST"
echo "archive_root: $ARCHIVE_ROOT"
echo "index_path: $INDEX_PATH"
if [ -f "$HERE/VERSION" ]; then
  echo "installed_version: $(cat "$HERE/VERSION")"
fi
echo "verify: $BIN_DIR/clipboard-archive health"
