#!/usr/bin/env bash
# The release-folder installer leaves exactly one copy of the app, where the
# disk image puts it, and the uninstaller removes every copy.
#
# Everything runs in a scratch home with a scratch stand-in for /Applications,
# a stub app and a fake launchctl. It never looks at the real /Applications,
# never starts an app and never touches a real login item.
set -euo pipefail
export PATH="/usr/bin:/bin:/usr/sbin:/sbin:${PATH:-}"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
T="$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/clipboard-archive-install-locations.XXXXXX")"
cleanup() {
  /bin/chmod -R u+w "$T" 2>/dev/null || true
  /bin/rm -rf "$T"
}
trap cleanup EXIT

failures=0
pass() { echo "ok   - $1"; }
fail() { echo "FAIL - $1" >&2; failures=$((failures + 1)); }
check() { # description, then a command that must succeed
  local description="$1"; shift
  if "$@" >/dev/null 2>&1; then pass "$description"; else fail "$description"; fi
}
refute() {
  local description="$1"; shift
  if "$@" >/dev/null 2>&1; then fail "$description"; else pass "$description"; fi
}

# A release folder: a stub app, the installer and the uninstaller.
RELEASE="$T/release"
/bin/mkdir -p "$RELEASE/ClipboardArchive.app/Contents/MacOS"
/usr/bin/printf '%s\n' '#!/bin/sh' 'exit 0' > "$RELEASE/ClipboardArchive.app/Contents/MacOS/ClipboardArchive"
/bin/chmod +x "$RELEASE/ClipboardArchive.app/Contents/MacOS/ClipboardArchive"
/usr/bin/printf '%s\n' 'new copy' > "$RELEASE/ClipboardArchive.app/Contents/new-sentinel.txt"
/bin/cp "$ROOT/scripts/install-release.sh" "$RELEASE/install.sh"
/bin/cp "$ROOT/scripts/uninstall-release.sh" "$RELEASE/uninstall.sh"
/bin/chmod +x "$RELEASE/install.sh" "$RELEASE/uninstall.sh"

OK_LAUNCHCTL="$T/launchctl-ok"
/usr/bin/printf '%s\n' '#!/bin/sh' 'exit 0' > "$OK_LAUNCHCTL"
FAILING_LAUNCHCTL="$T/launchctl-bootstrap-fails"
/usr/bin/printf '%s\n' '#!/bin/sh' 'if [ "${1:-}" = "bootstrap" ]; then exit 42; fi' 'exit 0' > "$FAILING_LAUNCHCTL"
/bin/chmod +x "$OK_LAUNCHCTL" "$FAILING_LAUNCHCTL"

old_copy() { # path
  /bin/mkdir -p "$1/Contents/MacOS"
  /usr/bin/printf '%s\n' 'old copy' > "$1/Contents/old-sentinel.txt"
}

# run <case> <launchctl> <pgrep> <script> [extra VAR=value ...]
run() {
  local name="$1" launchctl="$2" pgrep="$3" script="$4"; shift 4
  /usr/bin/env -i PATH="$PATH" HOME="$T/$name/home" TMPDIR="${TMPDIR:-/tmp}" \
    CLIPBOARD_ARCHIVE_SYSTEM_APP_DIR="$T/$name/system-applications" \
    CLIPBOARD_ARCHIVE_LAUNCHCTL_BIN="$launchctl" \
    CLIPBOARD_ARCHIVE_PGREP_BIN="$pgrep" \
    "$@" "$RELEASE/$script" > "$T/$name/out.log" 2>&1
}
setup() {
  /bin/mkdir -p "$T/$1/home/Library/LaunchAgents" "$T/$1/system-applications"
}
copies() { # every app bundle in the case's two application folders
  /usr/bin/find "$T/$1/system-applications" "$T/$1/home/Applications" -maxdepth 1 -name '*.app' 2>/dev/null | /usr/bin/wc -l | /usr/bin/tr -d ' '
}

echo "## a first install goes where the disk image goes"
setup fresh
check "install succeeds" run fresh "$OK_LAUNCHCTL" /usr/bin/true install.sh
check "the app is /Applications/Clipboard Archive.app" test -f "$T/fresh/system-applications/Clipboard Archive.app/Contents/new-sentinel.txt"
check "there is exactly one copy" test "$(copies fresh)" = 1
check "the login item starts that copy" /usr/bin/grep -q "<string>$T/fresh/system-applications/Clipboard Archive.app</string>" "$T/fresh/home/Library/LaunchAgents/app.clipboardarchive.plist"
check "the login item is a valid property list" /usr/bin/plutil -lint "$T/fresh/home/Library/LaunchAgents/app.clipboardarchive.plist"
refute "no data location is pinned when none was asked for" /usr/bin/grep -q "CLIPBOARD_ARCHIVE_ARCHIVE_ROOT" "$T/fresh/home/Library/LaunchAgents/app.clipboardarchive.plist"

echo "## an update replaces a copy the old installer left in ~/Applications"
setup old-location
old_copy "$T/old-location/home/Applications/ClipboardArchive.app"
check "install succeeds" run old-location "$OK_LAUNCHCTL" /usr/bin/true install.sh
check "the new copy is in /Applications" test -f "$T/old-location/system-applications/Clipboard Archive.app/Contents/new-sentinel.txt"
refute "the old copy is gone" test -e "$T/old-location/home/Applications/ClipboardArchive.app"
check "there is exactly one copy" test "$(copies old-location)" = 1
check "the installer says which copy it removed" /usr/bin/grep -q "removed_other_copy: $T/old-location/home/Applications/ClipboardArchive.app" "$T/old-location/out.log"

echo "## an update over the disk image copy replaces it in place"
setup disk-image
old_copy "$T/disk-image/system-applications/Clipboard Archive.app"
check "install succeeds" run disk-image "$OK_LAUNCHCTL" /usr/bin/true install.sh
check "the copy in /Applications is the new one" test -f "$T/disk-image/system-applications/Clipboard Archive.app/Contents/new-sentinel.txt"
refute "nothing of the old copy is left in it" test -e "$T/disk-image/system-applications/Clipboard Archive.app/Contents/old-sentinel.txt"
check "there is exactly one copy" test "$(copies disk-image)" = 1
refute "no second copy appears in ~/Applications" test -e "$T/disk-image/home/Applications"

echo "## without write access to /Applications the app goes to ~/Applications"
setup no-access
/bin/chmod 555 "$T/no-access/system-applications"
check "install succeeds" run no-access "$OK_LAUNCHCTL" /usr/bin/true install.sh
check "the app is ~/Applications/Clipboard Archive.app" test -f "$T/no-access/home/Applications/Clipboard Archive.app/Contents/new-sentinel.txt"
check "there is exactly one copy" test "$(copies no-access)" = 1

echo "## a copy this account cannot remove stops the install"
setup locked-copy
old_copy "$T/locked-copy/system-applications/Clipboard Archive.app"
/bin/chmod 555 "$T/locked-copy/system-applications"
refute "install refuses" run locked-copy "$OK_LAUNCHCTL" /usr/bin/true install.sh
check "the existing copy is untouched" test -f "$T/locked-copy/system-applications/Clipboard Archive.app/Contents/old-sentinel.txt"
refute "no second copy was installed" test -e "$T/locked-copy/home/Applications/Clipboard Archive.app"
check "there is exactly one copy" test "$(copies locked-copy)" = 1

echo "## a failed start puts every copy back"
setup rollback
old_copy "$T/rollback/home/Applications/ClipboardArchive.app"
old_copy "$T/rollback/system-applications/Clipboard Archive.app"
/usr/bin/printf '%s\n' 'previous login item' > "$T/rollback/home/Library/LaunchAgents/app.clipboardarchive.plist"
refute "install reports the failure" run rollback "$FAILING_LAUNCHCTL" /usr/bin/false install.sh
check "the copy in /Applications is the old one again" test -f "$T/rollback/system-applications/Clipboard Archive.app/Contents/old-sentinel.txt"
refute "the new copy is not left behind" test -e "$T/rollback/system-applications/Clipboard Archive.app/Contents/new-sentinel.txt"
check "the old-location copy is back" test -f "$T/rollback/home/Applications/ClipboardArchive.app/Contents/old-sentinel.txt"
check "the previous login item is back" /usr/bin/grep -q "previous login item" "$T/rollback/home/Library/LaunchAgents/app.clipboardarchive.plist"
check "no backup or staging folders are left" test -z "$(/usr/bin/find "$T/rollback/system-applications" "$T/rollback/home/Applications" -maxdepth 1 -name '.*app*' 2>/dev/null)"

echo "## a data location is pinned only when asked for, and survives odd characters"
setup custom-data
check "install succeeds" run custom-data "$OK_LAUNCHCTL" /usr/bin/true install.sh \
  "CLIPBOARD_ARCHIVE_ARCHIVE_ROOT=$T/custom-data/home/Documents/My Clips & More" \
  "CLIPBOARD_ARCHIVE_INDEX_PATH=$T/custom-data/home/Documents/index.sqlite"
PLIST="$T/custom-data/home/Library/LaunchAgents/app.clipboardarchive.plist"
check "the login item is a valid property list" /usr/bin/plutil -lint "$PLIST"
check "the archive location is pinned" test "$(/usr/bin/plutil -extract EnvironmentVariables.CLIPBOARD_ARCHIVE_ARCHIVE_ROOT raw -o - "$PLIST" 2>/dev/null)" = "$T/custom-data/home/Documents/My Clips & More"
check "the index location is pinned" test "$(/usr/bin/plutil -extract EnvironmentVariables.CLIPBOARD_ARCHIVE_INDEX_PATH raw -o - "$PLIST" 2>/dev/null)" = "$T/custom-data/home/Documents/index.sqlite"

echo "## uninstall removes every copy and keeps the data"
setup uninstall
old_copy "$T/uninstall/home/Applications/ClipboardArchive.app"
old_copy "$T/uninstall/system-applications/Clipboard Archive.app"
/bin/mkdir -p "$T/uninstall/home/Library/Application Support/ClipboardArchive/Archive" "$T/uninstall/home/.local/bin"
/usr/bin/printf '%s\n' 'history' > "$T/uninstall/home/Library/Application Support/ClipboardArchive/Archive/keep.txt"
/usr/bin/printf '%s\n' 'login item' > "$T/uninstall/home/Library/LaunchAgents/app.clipboardarchive.plist"
/usr/bin/printf '%s\n' 'cli' > "$T/uninstall/home/.local/bin/clipboard-archive"
check "uninstall succeeds" run uninstall "$OK_LAUNCHCTL" /usr/bin/true uninstall.sh
check "no copy of the app is left" test "$(copies uninstall)" = 0
refute "the login item is gone" test -e "$T/uninstall/home/Library/LaunchAgents/app.clipboardarchive.plist"
refute "the command-line tool is gone" test -e "$T/uninstall/home/.local/bin/clipboard-archive"
check "clipboard history is still there" test -f "$T/uninstall/home/Library/Application Support/ClipboardArchive/Archive/keep.txt"

if [ "$failures" -gt 0 ]; then
  echo "install location test failed: $failures check(s)" >&2
  exit 1
fi
echo "install location test ok"
