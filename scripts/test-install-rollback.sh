#!/usr/bin/env bash
set -euo pipefail
export PATH="/usr/bin:/bin:/usr/sbin:/sbin:${PATH:-}"

RELEASE_DIR="${1:-}"
if [ -z "$RELEASE_DIR" ] || [ ! -x "$RELEASE_DIR/install.sh" ]; then
  echo "usage: $0 /path/to/release-folder" >&2
  exit 1
fi

TEST_ROOT="$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/clipboard-archive-install-test.XXXXXX")"
cleanup() {
  /bin/rm -rf "$TEST_ROOT"
}
trap cleanup EXIT

TEST_HOME="$TEST_ROOT/home"
APP_DIR="$TEST_HOME/Applications"
BIN_DIR="$TEST_HOME/.local/bin"
PLIST_DIR="$TEST_HOME/Library/LaunchAgents"
APP_TARGET="$APP_DIR/ClipboardArchive.app"
PLIST="$PLIST_DIR/app.clipboardarchive.plist"
FAKE_LAUNCHCTL="$TEST_ROOT/fake-launchctl"
INSTALL_LOG="$TEST_ROOT/install.log"

/bin/mkdir -p "$APP_TARGET" "$PLIST_DIR"
/usr/bin/printf '%s\n' 'synthetic previous app' > "$APP_TARGET/previous-sentinel.txt"
/usr/bin/printf '%s\n' 'synthetic previous launch agent' > "$PLIST"
/usr/bin/printf '%s\n' \
  '#!/usr/bin/env bash' \
  'if [ "${1:-}" = "bootstrap" ]; then exit 42; fi' \
  'exit 0' > "$FAKE_LAUNCHCTL"
/bin/chmod +x "$FAKE_LAUNCHCTL"

set +e
HOME="$TEST_HOME" \
CLIPBOARD_ARCHIVE_APP_DIR="$APP_DIR" \
CLIPBOARD_ARCHIVE_BIN_DIR="$BIN_DIR" \
CLIPBOARD_ARCHIVE_ARCHIVE_ROOT="$TEST_HOME/archive" \
CLIPBOARD_ARCHIVE_INDEX_PATH="$TEST_HOME/indexes/search.sqlite" \
CLIPBOARD_ARCHIVE_LAUNCHCTL_BIN="$FAKE_LAUNCHCTL" \
CLIPBOARD_ARCHIVE_PGREP_BIN="/usr/bin/false" \
  "$RELEASE_DIR/install.sh" >"$INSTALL_LOG" 2>&1
status=$?
set -e

if [ "$status" -eq 0 ]; then
  /bin/cat "$INSTALL_LOG" >&2
  echo "rollback test failed: synthetic launch failure returned success" >&2
  exit 1
fi
if [ ! -f "$APP_TARGET/previous-sentinel.txt" ]; then
  /bin/cat "$INSTALL_LOG" >&2
  echo "rollback test failed: previous app sentinel is missing" >&2
  exit 1
fi
if [ "$(/usr/bin/sed -n '1p' "$APP_TARGET/previous-sentinel.txt")" != "synthetic previous app" ]; then
  /bin/cat "$INSTALL_LOG" >&2
  echo "rollback test failed: previous app was not restored" >&2
  exit 1
fi
if [ "$(/usr/bin/sed -n '1p' "$PLIST")" != "synthetic previous launch agent" ]; then
  /bin/cat "$INSTALL_LOG" >&2
  echo "rollback test failed: previous LaunchAgent was not restored" >&2
  exit 1
fi

echo "install rollback test ok"
