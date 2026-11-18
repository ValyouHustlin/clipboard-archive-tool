#!/usr/bin/env bash
# An update must not cost anyone their history, their settings or their data
# location. This installs today's release folder over the state earlier
# releases left behind and then reads that state back with today's
# command-line tool.
#
# The starting states are written the way those releases wrote them: the
# 0.1.2 settings file and event line below are byte-for-byte what the public
# 0.1.2 build produces. Everything runs in a scratch home with a scratch
# stand-in for /Applications, a stub app and a fake launchctl, and the
# command-line tool runs in a sandbox that cannot write outside the scratch
# tree. It never starts an app and never reads the clipboard.
set -euo pipefail
export PATH="/usr/bin:/bin:/usr/sbin:/sbin:${PATH:-}"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CLI="${CLIPBOARD_ARCHIVE_TEST_CLI:-}"
if [ -z "$CLI" ]; then
  (cd "$ROOT" && /usr/bin/xcrun swift build --product clipboard-archive >/dev/null)
  CLI="$ROOT/.build/debug/clipboard-archive"
fi
[ -x "$CLI" ] || { echo "no command-line tool at $CLI" >&2; exit 1; }

T="$(/usr/bin/mktemp -d /tmp/clipboard-archive-upgrade.XXXXXX)"
# The sandbox rule needs the folder's real path; everything else uses the
# path as the tools print it.
T_REAL="$(cd "$T" && pwd -P)"
cleanup() { /bin/rm -rf "$T"; }
trap cleanup EXIT

failures=0
pass() { echo "ok   - $1"; }
fail() { echo "FAIL - $1" >&2; failures=$((failures + 1)); }
check() {
  local description="$1"; shift
  if "$@" >/dev/null 2>&1; then pass "$description"; else fail "$description"; fi
}
refute() {
  local description="$1"; shift
  if "$@" >/dev/null 2>&1; then fail "$description"; else pass "$description"; fi
}

# Today's release folder: a stub app plus the installer under test.
RELEASE="$T/release"
/bin/mkdir -p "$RELEASE/ClipboardArchive.app/Contents/MacOS"
/usr/bin/printf '%s\n' '#!/bin/sh' 'exit 0' > "$RELEASE/ClipboardArchive.app/Contents/MacOS/ClipboardArchive"
/bin/chmod +x "$RELEASE/ClipboardArchive.app/Contents/MacOS/ClipboardArchive"
/bin/cp "$ROOT/scripts/install-release.sh" "$RELEASE/install.sh"
/bin/chmod +x "$RELEASE/install.sh"
LAUNCHCTL="$T/launchctl"
/usr/bin/printf '%s\n' '#!/bin/sh' 'exit 0' > "$LAUNCHCTL"
/bin/chmod +x "$LAUNCHCTL"

# The command-line tool may write only inside the scratch tree (and the
# per-user temporary folder Foundation uses for atomic writes).
SANDBOX="$T/cli.sb"
/usr/bin/printf '%s\n' \
  '(version 1)' '(allow default)' '(deny network-outbound)' '(deny file-write*)' \
  "(allow file-write* (subpath \"$T_REAL\") (literal \"/dev/null\") (regex #\"^/private/var/folders/[^/]+/[^/]+/T/\"))" \
  > "$SANDBOX"

CLIP_ID="clip_20270115T080000Z_fda6d439ff6a_7f2e8e69"
EVENT_LINE='{"allowedUse":["local-search","local-analysis"],"byteCount":38,"capturedAt":"2027-01-15T08:00:00Z","characterCount":38,"contentHash":"sha256:fda6d439ff6a949835766599e123baae0d18e8794eaf314db842bec861206fe5","contentPreview":"Clipboard Archive local self-test note","contentType":"text","id":"clip_20270115T080000Z_fda6d439ff6a_7f2e8e69","lineCount":1,"pasteboardTypes":["public.utf8-plain-text"],"privacyLabel":"private-local","rawContentPath":"raw/2027/01/2027-01-15_large-items/clip_20270115T080000Z_fda6d439ff6a_7f2e8e69.txt","sensitivityFlags":[],"sourceApp":{"bundleIdentifier":"com.apple.Safari","name":"Safari"},"uiVisibleUntil":"2027-01-22T08:00:00Z"}'

write_archive() { # archive root, as 0.1.2 lays it out
  local archive="$1"
  /bin/mkdir -p "$archive/raw/2027/01/2027-01-15_large-items"
  /usr/bin/printf '%s\n' "$EVENT_LINE" > "$archive/raw/2027/01/2027-01-15_clipboard-events.ndjson"
  /usr/bin/printf '%s' 'Clipboard Archive local self-test note' \
    > "$archive/raw/2027/01/2027-01-15_large-items/$CLIP_ID.txt"
  # What later releases add beside the clips: pins and tags, and the record
  # of what was deleted.
  /bin/mkdir -p "$archive/annotations" "$archive/deletion-ledger"
  /bin/cat > "$archive/annotations/annotations.json" <<'JSON'
{"annotations":{"sha256:fda6d439ff6a949835766599e123baae0d18e8794eaf314db842bec861206fe5":{"pinned":true,"pinnedAt":"2026-10-01T00:00:00Z","snippet":false,"tags":["keep","work"]}},"annotationsVersion":1,"collections":[],"updatedAt":"2026-10-01T00:00:00Z"}
JSON
  /usr/bin/printf '%s\n' '{"clipboardEventID":"clip_20260901T000000Z_aaaaaaaaaaaa_bbbbbbbb","deletedAt":"2026-09-02T00:00:00Z","eventType":"clipboard_event_deleted","reason":"manual-delete"}' \
    > "$archive/deletion-ledger/2026-09-02_deletions.ndjson"
  /bin/chmod -R go-rwx "$archive"
}

write_modern_settings() { # home; a 0.4.x settings file with every later choice set away from its default
  local support="$1/Library/Application Support/ClipboardArchive"
  /bin/mkdir -p "$support"
  /bin/cat > "$support/settings.json" <<'JSON'
{"appPrivacyRules":{"com.example.crm":{"addedAt":"2026-10-01T00:00:00Z","mode":"store-no-index"}},"archiveEnabled":true,"captureRichContent":false,"excludedAppNameFragments":["private notes"],"excludedBundleIdentifiers":["com.example.bank","com.example.crm"],"hasCompletedOnboarding":true,"historyGroupDuplicates":true,"historyWindow":30,"lastSeenAppVersion":"0.4.4","pollIntervalSeconds":0.5,"quickPickerDirectPasteEnabled":true,"recentItemLimit":120,"retentionMode":"unlimited","richImageMaxBytes":2097152,"settingsVersion":1,"shortcuts":{"quickPicker":{"enabled":true,"keyCode":9,"modifiers":["command","option"]}},"showBlockedEventStatus":false}
JSON
}

write_settings() { # home; the file 0.1.2 saves, with choices that differ from every default
  local support="$1/Library/Application Support/ClipboardArchive"
  /bin/mkdir -p "$support"
  /bin/cat > "$support/settings.json" <<'JSON'
{
  "archiveEnabled" : true,
  "excludedAppNameFragments" : [
    "private notes"
  ],
  "excludedBundleIdentifiers" : [
    "com.example.bank"
  ],
  "pollIntervalSeconds" : 0.5,
  "recentItemLimit" : 120,
  "retentionMode" : "unlimited"
}
JSON
}

write_old_install() { # home, archive root or "", index path or ""
  local home="$1" archive="$2" index="$3" pins=""
  /bin/mkdir -p "$home/Applications/ClipboardArchive.app/Contents/MacOS" "$home/.local/bin" "$home/Library/LaunchAgents"
  /usr/bin/printf '%s\n' 'old cli' > "$home/.local/bin/clipboard-archive"
  if [ -n "$archive" ]; then
    pins="  <key>EnvironmentVariables</key>
  <dict>
    <key>CLIPBOARD_ARCHIVE_ARCHIVE_ROOT</key>
    <string>$archive</string>
    <key>CLIPBOARD_ARCHIVE_INDEX_PATH</key>
    <string>$index</string>
  </dict>
"
  fi
  /bin/cat > "$home/Library/LaunchAgents/app.clipboardarchive.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
 "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>app.clipboardarchive</string>
  <key>ProgramArguments</key>
  <array>
    <string>/usr/bin/open</string>
    <string>$home/Applications/ClipboardArchive.app</string>
  </array>
  <key>RunAtLoad</key>
  <true/>
  <key>KeepAlive</key>
  <false/>
${pins}  <key>StandardOutPath</key>
  <string>$home/Library/Logs/ClipboardArchive/launchagent.out.log</string>
  <key>StandardErrorPath</key>
  <string>$home/Library/Logs/ClipboardArchive/launchagent.err.log</string>
</dict>
</plist>
PLIST
}

digest() { # one hash over every file's path, mode and bytes under the given paths
  local path
  for path in "$@"; do
    /usr/bin/find "$path" -type f -print0 | /usr/bin/sort -z | while IFS= read -r -d '' file; do
      echo "$(/usr/bin/stat -f '%Lp' "$file") $(/usr/bin/shasum -a 256 "$file")"
    done
  done | /usr/bin/shasum -a 256 | /usr/bin/cut -d' ' -f1
}

install_update() { # case name, then extra VAR=value for the installer
  local name="$1"; shift
  /usr/bin/env -i PATH="$PATH" HOME="$T/$name/home" \
    CLIPBOARD_ARCHIVE_SYSTEM_APP_DIR="$T/$name/system-applications" \
    CLIPBOARD_ARCHIVE_LAUNCHCTL_BIN="$LAUNCHCTL" \
    CLIPBOARD_ARCHIVE_PGREP_BIN=/usr/bin/true \
    "$@" "$RELEASE/install.sh" > "$T/$name/install.log" 2>&1
}

pin() { # case name, variable: what the rewritten login item hands the app
  /usr/bin/plutil -extract "EnvironmentVariables.$2" raw -o - \
    "$T/$1/home/Library/LaunchAgents/app.clipboardarchive.plist" 2>/dev/null || true
}

# Today's command-line tool, seeing what the app would see: the scratch home
# and whatever the login item pins. Never the application-support override,
# so this exercises the real default resolution.
cli() { # case name, then arguments
  local name="$1"; shift
  local archive index
  archive="$(pin "$name" CLIPBOARD_ARCHIVE_ARCHIVE_ROOT)"
  index="$(pin "$name" CLIPBOARD_ARCHIVE_INDEX_PATH)"
  /usr/bin/env -i PATH="$PATH" HOME="$T/$name/home" CFFIXED_USER_HOME="$T/$name/home" \
    ${archive:+"CLIPBOARD_ARCHIVE_ARCHIVE_ROOT=$archive"} \
    ${index:+"CLIPBOARD_ARCHIVE_INDEX_PATH=$index"} \
    /usr/bin/sandbox-exec -f "$SANDBOX" "$CLI" "$@"
}

json_field() { # json text, python expression over `d`
  /usr/bin/python3 -c 'import json, sys; d = json.loads(sys.argv[1]); print(eval(sys.argv[2]))' "$1" "$2"
}

# The checks every case shares, once the update has run.
check_carried_over() { # case name, expected archive root, digest before, paths digested...
  local name="$1" archive="$2" before="$3"; shift 3
  local home="$T/$name/home" stores status
  check "history, pins, tags, deletion record and settings are byte-for-byte what they were" test "$(digest "$@")" = "$before"
  check "one copy of the app, in /Applications" test -x "$T/$name/system-applications/Clipboard Archive.app/Contents/MacOS/ClipboardArchive"
  refute "the copy in ~/Applications is gone" test -e "$home/Applications/ClipboardArchive.app"

  stores="$(cli "$name" stores --json 2>/dev/null || true)"
  # Before trusting any other answer: the tool must be looking at the
  # scratch home, not at a real one.
  if [ "$(json_field "$stores" 'd["settings"]["path"]' 2>/dev/null)" != "$home/Library/Application Support/ClipboardArchive/settings.json" ]; then
    fail "the command-line tool resolved a settings path outside the scratch home; later checks skipped"
    return
  fi
  check "the app is pointed at the same history" test "$(json_field "$stores" 'd["archive"]["path"]')" = "$archive"
  local scanned indexed warnings
  scanned="$(cli "$name" search 'self-test note' --scan 2>/dev/null || true)"
  check "the old clip is read straight from the history files" /usr/bin/grep -q "$CLIP_ID" <<<"$scanned"
  check "the search index is rebuilt from the history" cli "$name" repair-index
  indexed="$(cli "$name" search 'self-test note' 2>/dev/null || true)"
  check "the old clip is found by search" /usr/bin/grep -q "$CLIP_ID" <<<"$indexed"
  check "the pinned clip is still pinned" /usr/bin/grep -q '^pinned_items: 1$' <<<"$(cli "$name" health 2>/dev/null || true)"
  status="$(cli "$name" status --json 2>/dev/null || true)"
  check "capture is still switched on" test "$(json_field "$status" 'd["capture_enabled"]')" = "True"
  warnings="$(json_field "$status" '" | ".join(d["warnings"])' 2>/dev/null || true)"
  refute "the settings were not replaced by defaults" /usr/bin/grep -q 'Settings are not fully readable' <<<"$warnings"
  check "reading changed nothing in the history or settings" test "$(digest "$@")" = "$before"
}

echo "## from 0.1.2, default data location"
name=from-0.1.2-default; home="$T/$name/home"; /bin/mkdir -p "$home" "$T/$name/system-applications"
archive="$home/Library/Application Support/ClipboardArchive/Archive/clipboard-history"
index="$home/Library/Application Support/ClipboardArchive/Indexes/clipboard-search.sqlite"
write_settings "$home"; write_archive "$archive"; write_old_install "$home" "$archive" "$index"
before="$(digest "$archive/raw" "$archive/annotations" "$archive/deletion-ledger" "$home/Library/Application Support/ClipboardArchive/settings.json")"
check "the update installs" install_update "$name"
check_carried_over "$name" "$archive" "$before" "$archive/raw" "$archive/annotations" "$archive/deletion-ledger" "$home/Library/Application Support/ClipboardArchive/settings.json"

echo "## from 0.1.2, history kept in a folder the user chose"
name=from-0.1.2-custom; home="$T/$name/home"; /bin/mkdir -p "$home" "$T/$name/system-applications"
archive="$home/Documents/My Clipboard/Archive"
index="$home/Documents/My Clipboard/clipboard-search.sqlite"
write_settings "$home"; write_archive "$archive"; write_old_install "$home" "$archive" "$index"
before="$(digest "$archive/raw" "$archive/annotations" "$archive/deletion-ledger" "$home/Library/Application Support/ClipboardArchive/settings.json")"
check "the update installs, with no location given" install_update "$name"
check "the login item still names the chosen folder" test "$(pin "$name" CLIPBOARD_ARCHIVE_ARCHIVE_ROOT)" = "$archive"
check "the login item still names the chosen index" test "$(pin "$name" CLIPBOARD_ARCHIVE_INDEX_PATH)" = "$index"
refute "nothing was started in the default location" test -e "$home/Library/Application Support/ClipboardArchive/Archive"
check_carried_over "$name" "$archive" "$before" "$archive/raw" "$archive/annotations" "$archive/deletion-ledger" "$home/Library/Application Support/ClipboardArchive/settings.json"

echo "## a location given at update time wins over the old one"
name=moved-on-purpose; home="$T/$name/home"; /bin/mkdir -p "$home" "$T/$name/system-applications"
old_archive="$home/Documents/Old Place/Archive"
archive="$home/Documents/New Place/Archive"
index="$home/Documents/New Place/clipboard-search.sqlite"
write_settings "$home"; write_archive "$old_archive"; write_archive "$archive"
write_old_install "$home" "$old_archive" "$home/Documents/Old Place/clipboard-search.sqlite"
before="$(digest "$archive/raw" "$archive/annotations" "$archive/deletion-ledger" "$home/Library/Application Support/ClipboardArchive/settings.json")"
check "the update installs" install_update "$name" "CLIPBOARD_ARCHIVE_ARCHIVE_ROOT=$archive" "CLIPBOARD_ARCHIVE_INDEX_PATH=$index"
check "the old location's files are left alone" test -f "$old_archive/raw/2027/01/2027-01-15_clipboard-events.ndjson"
check_carried_over "$name" "$archive" "$before" "$archive/raw" "$archive/annotations" "$archive/deletion-ledger" "$home/Library/Application Support/ClipboardArchive/settings.json"

echo "## from 0.3.0 or later, location remembered by the app itself"
name=from-pointer; home="$T/$name/home"; /bin/mkdir -p "$home" "$T/$name/system-applications"
archive="$home/Documents/Remembered/Archive"
index="$home/Documents/Remembered/clipboard-search.sqlite"
write_settings "$home"; write_archive "$archive"; write_old_install "$home" "" ""
/usr/bin/python3 -c '
import json, sys
json.dump({"schema": 1, "archiveRoot": sys.argv[1], "archiveOrigin": "env", "indexPath": sys.argv[2],
           "indexOrigin": "env", "updatedAt": "2026-11-01T00:00:00.000Z", "writtenBy": "ClipboardArchive 0.4.1 (11)"},
          open(sys.argv[3], "w"))
' "$archive" "$index" "$home/Library/Application Support/ClipboardArchive/stores.json"
before="$(digest "$archive/raw" "$archive/annotations" "$archive/deletion-ledger" "$home/Library/Application Support/ClipboardArchive/settings.json" "$home/Library/Application Support/ClipboardArchive/stores.json")"
check "the update installs" install_update "$name"
refute "the installer pins nothing it was not given" test -n "$(pin "$name" CLIPBOARD_ARCHIVE_ARCHIVE_ROOT)"
check_carried_over "$name" "$archive" "$before" "$archive/raw" "$archive/annotations" "$archive/deletion-ledger" "$home/Library/Application Support/ClipboardArchive/settings.json" "$home/Library/Application Support/ClipboardArchive/stores.json"

echo "## from 0.4.4, with every later setting changed from its default"
name=from-0.4.4; home="$T/$name/home"; /bin/mkdir -p "$home" "$T/$name/system-applications"
archive="$home/Documents/Remembered/Archive"
index="$home/Documents/Remembered/clipboard-search.sqlite"
write_modern_settings "$home"; write_archive "$archive"; write_old_install "$home" "$archive" "$index"
/bin/rm -rf "$home/Applications"; /bin/mkdir -p "$T/$name/system-applications/Clipboard Archive.app/Contents/MacOS"
before="$(digest "$archive/raw" "$archive/annotations" "$archive/deletion-ledger" "$home/Library/Application Support/ClipboardArchive/settings.json")"
check "the update installs" install_update "$name"
check_carried_over "$name" "$archive" "$before" "$archive/raw" "$archive/annotations" "$archive/deletion-ledger" "$home/Library/Application Support/ClipboardArchive/settings.json"

if [ "$failures" -gt 0 ]; then
  echo "upgrade test failed: $failures check(s)" >&2
  exit 1
fi
echo "upgrade test ok"
