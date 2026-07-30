#!/usr/bin/env bash
set -euo pipefail
export PATH="/usr/bin:/bin:/usr/sbin:/sbin:${PATH:-}"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RELEASE_DIR="${1:-}"

production_source_matches="$(
  rg -n \
    'URLSession|NSURLConnection|CFNetwork|Network\.framework|NWConnection|NWPath|WebSocket|CloudKit|CKContainer|WKWebView|SFSafari|Sparkle|SUUpdater|Telemetry|analytics|crashlytics|firebase|curl|wget|scp|rsync|http://|https://' \
    "$ROOT/Sources/ClipboardArchiveCore" \
    "$ROOT/Sources/ClipboardArchiveMenuBar" \
    "$ROOT/Sources/clipboard-archive" \
    "$ROOT/Sources/ClipboardArchiveChecks" \
    "$ROOT/Package.swift" \
    2>/dev/null \
    | rg -v 'github\.com/swiftlang/swift-testing\.git' \
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

if [ -n "$production_source_matches" ]; then
  echo "local-only check failed: production source references network/update APIs" >&2
  echo "$production_source_matches" >&2
  exit 1
fi

installer_matches="$(
  rg -n \
    'curl|wget|scp|rsync|http://|https://|Sparkle|SUUpdater|Homebrew|brew install|softwareupdate' \
    "$ROOT/scripts/install-release.sh" \
    "$ROOT/scripts/uninstall-release.sh" \
    2>/dev/null | rg -v 'www\.apple\.com/DTDs/PropertyList-1\.0\.dtd' || true
)"

if [ -n "$installer_matches" ]; then
  echo "local-only check failed: release installer references network/update behavior" >&2
  echo "$installer_matches" >&2
  exit 1
fi

if [ -n "$RELEASE_DIR" ]; then
  app_binary="$RELEASE_DIR/ClipboardArchive.app/Contents/MacOS/ClipboardArchive"
  cli_binary="$RELEASE_DIR/bin/clipboard-archive"
  for binary in "$app_binary" "$cli_binary"; do
    if [ ! -x "$binary" ]; then
      echo "local-only check failed: missing executable $binary" >&2
      exit 1
    fi
    linked_network_frameworks="$(otool -L "$binary" | rg 'CFNetwork|Network\.framework|WebKit|CloudKit|SecurityFoundation|SafariServices' || true)"
    if [ -n "$linked_network_frameworks" ]; then
      echo "local-only check failed: $binary links network/cloud frameworks" >&2
      echo "$linked_network_frameworks" >&2
      exit 1
    fi
    binary_network_strings="$(
      strings "$binary" \
        | rg 'URLSession|NSURLConnection|CFNetwork|NWConnection|CloudKit|WebSocket|Sparkle|SUUpdater|https?://' \
        | rg -v '^application:userDidAcceptCloudKitShareWithMetadata:$' \
        | rg -v '^https://github\.com/ValyouHustlin/clipboard-archive-tool/releases$' \
        || true
    )"
    # The exact release-page literal (and nothing else URL-shaped) is
    # allowed in shipped binaries: it is the About section's manual-update
    # pointer, exercised only by user-initiated copy/open actions.
    if [ -n "$binary_network_strings" ]; then
      echo "local-only check failed: $binary contains network/update strings" >&2
      echo "$binary_network_strings" >&2
      exit 1
    fi
  done
fi

echo "local-only check ok"
if [ -n "$RELEASE_DIR" ]; then
  echo "release_dir: $RELEASE_DIR"
fi
