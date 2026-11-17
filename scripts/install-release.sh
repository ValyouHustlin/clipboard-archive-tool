#!/usr/bin/env bash
# Install or update Clipboard Archive from a release folder.
#
# One copy, in one place: the app lands where the disk image puts it,
# "/Applications/Clipboard Archive.app" (or the same name in ~/Applications
# when /Applications cannot be written). A copy left anywhere else by an
# older installer or a disk image is removed once the new one is running,
# because two copies share one bundle id, one login item and one archive.
set -euo pipefail
export PATH="/usr/bin:/bin:/usr/sbin:/sbin:${PATH:-}"

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_SOURCE="${HERE}/ClipboardArchive.app"
CLI_SOURCE="${HERE}/bin/clipboard-archive"
LABEL="app.clipboardarchive"
APP_NAME="Clipboard Archive.app"
# The name the release-folder installer used through 0.4.1.
OLD_APP_NAME="ClipboardArchive.app"
# Overridable so a test never looks at the real /Applications.
SYSTEM_APP_DIR="${CLIPBOARD_ARCHIVE_SYSTEM_APP_DIR:-/Applications}"
USER_APP_DIR="$HOME/Applications"
if [ -n "${CLIPBOARD_ARCHIVE_APP_DIR:-}" ]; then
  APP_DIR="$CLIPBOARD_ARCHIVE_APP_DIR"
elif [ -d "$SYSTEM_APP_DIR" ] && [ -w "$SYSTEM_APP_DIR" ]; then
  APP_DIR="$SYSTEM_APP_DIR"
else
  APP_DIR="$USER_APP_DIR"
fi
APP_TARGET="$APP_DIR/$APP_NAME"
APP_STAGE="$APP_DIR/.$APP_NAME.install-$$"
APP_BACKUP="$APP_DIR/.$APP_NAME.backup-$$"
BIN_DIR="${CLIPBOARD_ARCHIVE_BIN_DIR:-$HOME/.local/bin}"
# A data location given here wins. Without one, the location the existing
# login item pins is carried over (read below, once PLIST is known), so an
# update never moves anyone's history. With neither, the app resolves its
# own: the location it last published, or the default under Application
# Support.
ARCHIVE_ROOT="${CLIPBOARD_ARCHIVE_ARCHIVE_ROOT:-}"
INDEX_PATH="${CLIPBOARD_ARCHIVE_INDEX_PATH:-}"
PLIST="$HOME/Library/LaunchAgents/${LABEL}.plist"
PLIST_BACKUP="$HOME/Library/LaunchAgents/.${LABEL}.plist.backup-$$"
LOG_DIR="$HOME/Library/Logs/ClipboardArchive"
LAUNCHCTL_BIN="${CLIPBOARD_ARCHIVE_LAUNCHCTL_BIN:-/bin/launchctl}"
PGREP_BIN="${CLIPBOARD_ARCHIVE_PGREP_BIN:-/usr/bin/pgrep}"

# Every release through 0.4.1 wrote the data location into the login item and
# nowhere else that survives a reinstall. Rewriting the login item without it
# would start the app on the default location and the history would look lost.
existing_pin() {
  [ -f "$PLIST" ] || return 0
  /usr/bin/plutil -extract "EnvironmentVariables.$1" raw -o - "$PLIST" 2>/dev/null || true
}
if [ -z "$ARCHIVE_ROOT" ]; then
  ARCHIVE_ROOT="$(existing_pin CLIPBOARD_ARCHIVE_ARCHIVE_ROOT)"
fi
if [ -z "$INDEX_PATH" ]; then
  INDEX_PATH="$(existing_pin CLIPBOARD_ARCHIVE_INDEX_PATH)"
fi

usage() {
  cat <<'USAGE'
Install or update Clipboard Archive.

The app is installed as "Clipboard Archive.app" in /Applications, or in
~/Applications when /Applications cannot be written. Any other copy of the
app in either folder is removed after the new one starts.

Environment overrides:
  CLIPBOARD_ARCHIVE_APP_DIR       Folder to install into
  CLIPBOARD_ARCHIVE_BIN_DIR       Default: ~/.local/bin
  CLIPBOARD_ARCHIVE_ARCHIVE_ROOT  Where clipboard history is kept. Default: where it
                                  already is (first install: ~/Library/Application
                                  Support/ClipboardArchive)
  CLIPBOARD_ARCHIVE_INDEX_PATH    The search index file. Default: where it already is

An update keeps your history, settings, pins and tags, and the data location
of the copy it replaces.

Examples:
  ./install.sh
  CLIPBOARD_ARCHIVE_ARCHIVE_ROOT="$HOME/Documents/ClipboardArchive" ./install.sh
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

# Every other place a copy can be. Checked before anything is changed, so a
# copy this user cannot remove stops the install instead of becoming a second
# app.
OTHER_COPIES=()
for candidate in \
  "$SYSTEM_APP_DIR/$APP_NAME" \
  "$SYSTEM_APP_DIR/$OLD_APP_NAME" \
  "$USER_APP_DIR/$APP_NAME" \
  "$USER_APP_DIR/$OLD_APP_NAME" \
  "$APP_DIR/$OLD_APP_NAME"; do
  [ -d "$candidate" ] || continue
  [ "$candidate" = "$APP_TARGET" ] && continue
  duplicate=false
  for seen in ${OTHER_COPIES[@]+"${OTHER_COPIES[@]}"}; do
    [ "$seen" = "$candidate" ] && duplicate=true
  done
  [ "$duplicate" = true ] && continue
  if [ ! -w "$(dirname "$candidate")" ]; then
    echo "another copy is installed at $candidate and this account cannot remove it." >&2
    echo "remove that copy first, or install from an account that can; nothing was changed." >&2
    exit 1
  fi
  OTHER_COPIES+=("$candidate")
done

mkdir -p "$APP_DIR" "$BIN_DIR" "$HOME/Library/LaunchAgents" "$LOG_DIR"
if [ -n "$ARCHIVE_ROOT" ]; then
  mkdir -p "$(dirname "$ARCHIVE_ROOT")"
fi
if [ -n "$INDEX_PATH" ]; then
  mkdir -p "$(dirname "$INDEX_PATH")"
fi

rm -rf "$APP_STAGE" "$APP_BACKUP"
rm -f "$PLIST_BACKUP"
cp -R "$APP_SOURCE" "$APP_STAGE"
had_existing_plist=false
if [ -f "$PLIST" ]; then
  cp "$PLIST" "$PLIST_BACKUP"
  had_existing_plist=true
fi

had_existing_app=false
if [ -d "$APP_TARGET" ]; then
  had_existing_app=true
fi
old_app_moved=false
# Other copies that have been moved aside, so a rollback can put them back.
MOVED_COPIES=()

copy_backup_path() {
  echo "$(dirname "$1")/.$(basename "$1").backup-$$"
}

rollback_update() {
  "$LAUNCHCTL_BIN" bootout "gui/$(/usr/bin/id -u)" "$PLIST" >/dev/null 2>&1 || true
  rm -rf "$APP_STAGE" || true
  # Remove the target only when it is the new copy. Until the old app has
  # been moved aside the target is still the old app, and deleting it would
  # leave nothing to restore.
  if [ "$had_existing_app" = false ] || [ "$old_app_moved" = true ]; then
    rm -rf "$APP_TARGET" || true
  fi
  if [ -d "$APP_BACKUP" ]; then
    mv "$APP_BACKUP" "$APP_TARGET" || true
  fi
  for copy in ${MOVED_COPIES[@]+"${MOVED_COPIES[@]}"}; do
    mv "$(copy_backup_path "$copy")" "$copy" || true
  done
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

# Stop the running copy wherever it runs from. The lock names the one process
# that holds the archive; a copy left running from another folder would keep
# that lock and the new copy would exit at once.
LOCK_FILE="$HOME/Library/Application Support/ClipboardArchive/ClipboardArchive.lock"
if [ -f "$LOCK_FILE" ]; then
  running_pid="$(/usr/bin/tr -dc '0-9' < "$LOCK_FILE" || true)"
  if [ -n "$running_pid" ]; then
    running_command="$(/bin/ps -p "$running_pid" -o command= 2>/dev/null || true)"
    case "$running_command" in
      */Contents/MacOS/ClipboardArchive|*/Contents/MacOS/ClipboardArchive\ *)
        kill "$running_pid" >/dev/null 2>&1 || true
        for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15; do
          kill -0 "$running_pid" >/dev/null 2>&1 || break
          sleep 0.2
        done
        ;;
    esac
  fi
fi

if [ -d "$APP_TARGET" ]; then
  mv "$APP_TARGET" "$APP_BACKUP"
  old_app_moved=true
fi
for copy in ${OTHER_COPIES[@]+"${OTHER_COPIES[@]}"}; do
  mv "$copy" "$(copy_backup_path "$copy")"
  MOVED_COPIES+=("$copy")
done
mv "$APP_STAGE" "$APP_TARGET"

xml_escape() {
  printf '%s' "$1" | /usr/bin/sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g'
}

# Pin a data location only when the caller asked for one. launchd hands these
# to `open`, which passes its environment on to the app it starts, and
# `clipboard-archive status` reads the pinned stores from this block.
environment_block=""
if [ -n "$ARCHIVE_ROOT" ] || [ -n "$INDEX_PATH" ]; then
  environment_block="  <key>EnvironmentVariables</key>
  <dict>
"
  if [ -n "$ARCHIVE_ROOT" ]; then
    environment_block="${environment_block}    <key>CLIPBOARD_ARCHIVE_ARCHIVE_ROOT</key>
    <string>$(xml_escape "$ARCHIVE_ROOT")</string>
"
  fi
  if [ -n "$INDEX_PATH" ]; then
    environment_block="${environment_block}    <key>CLIPBOARD_ARCHIVE_INDEX_PATH</key>
    <string>$(xml_escape "$INDEX_PATH")</string>
"
  fi
  environment_block="${environment_block}  </dict>
"
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
    <string>$(xml_escape "$APP_TARGET")</string>
  </array>
  <key>RunAtLoad</key>
  <true/>
  <key>KeepAlive</key>
  <false/>
${environment_block}  <key>StandardOutPath</key>
  <string>$(xml_escape "$LOG_DIR/launchagent.out.log")</string>
  <key>StandardErrorPath</key>
  <string>$(xml_escape "$LOG_DIR/launchagent.err.log")</string>
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
for copy in ${MOVED_COPIES[@]+"${MOVED_COPIES[@]}"}; do
  rm -rf "$(copy_backup_path "$copy")"
  echo "removed_other_copy: $copy"
done

if [ -x "$CLI_SOURCE" ]; then
  cp "$CLI_SOURCE" "$BIN_DIR/clipboard-archive"
  chmod +x "$BIN_DIR/clipboard-archive"
fi

echo "installed_app: $APP_TARGET"
echo "installed_cli: $BIN_DIR/clipboard-archive"
echo "launch_agent: $PLIST"
if [ -n "$ARCHIVE_ROOT" ]; then
  echo "archive_root: $ARCHIVE_ROOT"
fi
if [ -n "$INDEX_PATH" ]; then
  echo "index_path: $INDEX_PATH"
fi
if [ -f "$HERE/VERSION" ]; then
  echo "installed_version: $(cat "$HERE/VERSION")"
fi
echo "stores: $BIN_DIR/clipboard-archive stores"
echo "verify: $BIN_DIR/clipboard-archive health"
