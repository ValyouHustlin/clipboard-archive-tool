#!/usr/bin/env bash
# The local-only boundary, checked mechanically.
#
# The process that reads the clipboard (the app, the CLI, the core library)
# has no network code at all. Updates are the one network feature, and they
# live in a separate helper process that has no clipboard code:
#   - only ClipboardArchiveUpdater may depend on Sparkle;
#   - ClipboardArchiveUpdater may not depend on ClipboardArchiveCore, and its
#     sources may not touch the pasteboard or the stores;
#   - the shipped app executable links no network framework and carries no
#     network strings beyond the one allowlisted release-page literal.
#
# usage: check-local-only.sh [RELEASE_DIR]   sources + a package-release.sh folder
#        check-local-only.sh --app APP       sources + an assembled .app (release.sh)
set -euo pipefail
export PATH="/usr/bin:/bin:/usr/sbin:/sbin:${PATH:-}"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RELEASE_DIR=""
APP=""
case "${1:-}" in
  --app) APP="${2:?--app needs a path}" ;;
  "") ;;
  *) RELEASE_DIR="$1" ;;
esac

fail() {
  echo "local-only check failed: $1" >&2
  [ -n "${2:-}" ] && printf '%s\n' "$2" >&2
  exit 1
}

# Every check below reads ripgrep's output; without it they would all see
# nothing and pass. Fail closed instead.
command -v rg >/dev/null 2>&1 || fail "ripgrep (rg) is required; without it this gate would check nothing"

NETWORK_SOURCE='URLSession|NSURLConnection|CFNetwork|Network\.framework|NWConnection|NWPath|WebSocket|CloudKit|CKContainer|WKWebView|SFSafari|Sparkle|SUUpdater|Telemetry|analytics|crashlytics|firebase|curl|wget|scp|rsync|http://|https://'

production_source_matches="$(
  rg -n "$NETWORK_SOURCE" \
    "$ROOT/Sources/ClipboardArchiveCore" \
    "$ROOT/Sources/ClipboardArchiveMenuBar" \
    "$ROOT/Sources/ClipboardArchiveUpdateRules" \
    "$ROOT/Sources/clipboard-archive" \
    "$ROOT/Sources/ClipboardArchiveChecks" \
    2>/dev/null \
    | rg -v 'https://example\.com/' \
    | rg -v '^[^:]*:[0-9]+: *"https://github\.com/ValyouHustlin/clipboard-archive-tool/releases"$' \
    || true
)"
# Allowlist note: the single release-page constant
# (ClipboardVersionInfo.releasePageURLString) is a display/copy/open-in-
# browser string for the Settings About section — never fetched by the app.
# The exemption is ANCHORED to a line that contains NOTHING but the quoted
# literal (the constant's continuation line), so a future line mixing this
# URL with real network code still fails the gate. Any OTHER URL or network
# API in production sources fails as before.
[ -z "$production_source_matches" ] \
  || fail "production source references network/update APIs" "$production_source_matches"

# The dependency graph, from the manifest itself rather than a text match.
graph_problems="$(
  cd "$ROOT" && swift package dump-package 2>/dev/null | /usr/bin/python3 -c '
import json, sys
manifest = json.load(sys.stdin)
problems = []
allowed_packages = {"swift-testing", "sparkle"}
for dependency in manifest.get("dependencies", []):
    for kind in dependency.values():
        for entry in kind:
            identity = entry.get("identity", "").lower()
            if identity not in allowed_packages:
                problems.append("unexpected package dependency: " + identity)
for target in manifest["targets"]:
    names = set()
    for dependency in target.get("dependencies", []):
        for value in dependency.values():
            names.add(value[0] if isinstance(value, list) else value)
    if "Sparkle" in names and target["name"] != "ClipboardArchiveUpdater":
        problems.append(target["name"] + " depends on Sparkle; only ClipboardArchiveUpdater may")
    if target["name"] == "ClipboardArchiveUpdater" and "ClipboardArchiveCore" in names:
        problems.append("ClipboardArchiveUpdater depends on ClipboardArchiveCore; the networked process must not hold clipboard code")
print("\n".join(problems))
' || echo "could not read the package manifest"
)"
[ -z "$graph_problems" ] || fail "package graph" "$graph_problems"

updater_source_matches="$(
  rg -n 'import ClipboardArchiveCore|NSPasteboard|clipboard-history|ArchiveRoot|CLIPBOARD_ARCHIVE_(ARCHIVE_ROOT|INDEX_PATH)|\.sqlite' \
    "$ROOT/Sources/ClipboardArchiveUpdater" 2>/dev/null || true
)"
[ -z "$updater_source_matches" ] \
  || fail "the update helper's sources reach for the clipboard or the stores" "$updater_source_matches"

installer_matches="$(
  rg -n \
    'curl|wget|scp|rsync|http://|https://|Sparkle|SUUpdater|Homebrew|brew install|softwareupdate' \
    "$ROOT/scripts/install-release.sh" \
    "$ROOT/scripts/uninstall-release.sh" \
    2>/dev/null | rg -v 'www\.apple\.com/DTDs/PropertyList-1\.0\.dtd' || true
)"
[ -z "$installer_matches" ] \
  || fail "release installer references network/update behavior" "$installer_matches"

check_local_binary() {
  local binary="$1"
  [ -x "$binary" ] || fail "missing executable $binary"
  local linked
  linked="$(otool -L "$binary" | rg 'CFNetwork|Network\.framework|WebKit|CloudKit|SecurityFoundation|SafariServices|Sparkle' || true)"
  [ -z "$linked" ] || fail "$binary links network/cloud/update frameworks" "$linked"
  local strings_found
  strings_found="$(
    strings "$binary" \
      | rg 'URLSession|NSURLConnection|CFNetwork|NWConnection|CloudKit|WebSocket|Sparkle|SUUpdater|https?://' \
      | rg -v '^application:userDidAcceptCloudKitShareWithMetadata:$' \
      | rg -v '^https://github\.com/ValyouHustlin/clipboard-archive-tool/releases$' \
      || true
  )"
  # The exact release-page literal (and nothing else URL-shaped) is
  # allowed in shipped binaries: it is the About section's manual-update
  # pointer, exercised only by user-initiated copy/open actions.
  [ -z "$strings_found" ] || fail "$binary contains network/update strings" "$strings_found"
}

if [ -n "$RELEASE_DIR" ]; then
  check_local_binary "$RELEASE_DIR/ClipboardArchive.app/Contents/MacOS/ClipboardArchive"
  check_local_binary "$RELEASE_DIR/bin/clipboard-archive"
fi

if [ -n "$APP" ]; then
  check_local_binary "$APP/Contents/MacOS/ClipboardArchive"
  helper="$APP/Contents/Helpers/Clipboard Archive Updater.app/Contents/MacOS/ClipboardArchiveUpdater"
  if [ -e "$helper" ]; then
    # Swift links its modules statically, so the helper's strings are where
    # core code would show; the pasteboard is the line it must not cross.
    helper_reach="$(strings "$helper" | rg 'ClipboardArchiveCore|NSPasteboard|generalPasteboard|clipboard-history' || true)"
    [ -z "$helper_reach" ] || fail "the update helper carries clipboard code" "$helper_reach"
  fi
  # Nothing networked may sit beside the app executable itself.
  stray="$(find "$APP/Contents" -name 'Sparkle.framework' -not -path '*/Helpers/*' || true)"
  [ -z "$stray" ] || fail "Sparkle is outside the update helper" "$stray"
fi

echo "local-only check ok"
[ -n "$RELEASE_DIR" ] && echo "release_dir: $RELEASE_DIR"
[ -n "$APP" ] && echo "app: $APP"
exit 0
