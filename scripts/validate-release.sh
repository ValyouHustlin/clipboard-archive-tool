#!/usr/bin/env bash
set -euo pipefail

RELEASE_DIR="${1:-}"

if [ -z "$RELEASE_DIR" ] || [ ! -d "$RELEASE_DIR" ]; then
  echo "usage: $0 /path/to/ClipboardArchive-<version>-macos-<arch>" >&2
  exit 1
fi

required=(
  "ClipboardArchive.app/Contents/Info.plist"
  "ClipboardArchive.app/Contents/MacOS/ClipboardArchive"
  "bin/clipboard-archive"
  "install.sh"
  "uninstall.sh"
  "manifest.json"
  "SHA256SUMS"
  "README.md"
  "PRIVACY.md"
  "LICENSE"
  "docs/CLI.md"
)

for path in "${required[@]}"; do
  if [ ! -e "$RELEASE_DIR/$path" ]; then
    echo "missing release file: $path" >&2
    exit 1
  fi
done

plutil -lint "$RELEASE_DIR/ClipboardArchive.app/Contents/Info.plist" >/dev/null
bash -n "$RELEASE_DIR/install.sh"
bash -n "$RELEASE_DIR/uninstall.sh"
# Validation is self-contained even when the caller has live store variables.
VERIFY_ROOT="$(mktemp -d /tmp/clipboard-release-validation.XXXXXX)"
trap 'rm -rf "$VERIFY_ROOT"' EXIT
export CLIPBOARD_ARCHIVE_APPLICATION_SUPPORT_ROOT="$VERIFY_ROOT/support"
export CLIPBOARD_ARCHIVE_ARCHIVE_ROOT="$VERIFY_ROOT/archive"
export CLIPBOARD_ARCHIVE_INDEX_PATH="$VERIFY_ROOT/index.sqlite"
unset CLIPBOARD_ARCHIVE_VERSION CLIPBOARD_ARCHIVE_BUILD
mkdir -p "$VERIFY_ROOT/bin"
cp "$RELEASE_DIR/bin/clipboard-archive" "$VERIFY_ROOT/bin/clipboard-archive"
CLI="$VERIFY_ROOT/bin/clipboard-archive"
"$CLI" self-test >/dev/null
"$CLI" version --json > "$VERIFY_ROOT/version.json"
"$CLI" version > "$VERIFY_ROOT/version.txt"
VERSION="$(/usr/bin/plutil -extract version raw -o - "$RELEASE_DIR/manifest.json")"
BUILD="$(/usr/bin/plutil -extract build raw -o - "$RELEASE_DIR/manifest.json")"
APP_INFO="$RELEASE_DIR/ClipboardArchive.app/Contents/Info.plist"
[ "$(/usr/bin/plutil -extract CFBundleShortVersionString raw -o - "$APP_INFO")" = "$VERSION" ]
[ "$(/usr/bin/plutil -extract CFBundleVersion raw -o - "$APP_INFO")" = "$BUILD" ]
[ "$(/usr/bin/plutil -extract app_version raw -o - "$VERIFY_ROOT/version.json")" = "$VERSION" ]
[ "$(/usr/bin/plutil -extract build raw -o - "$VERIFY_ROOT/version.json")" = "$BUILD" ]
[ "$(head -n 1 "$VERIFY_ROOT/version.txt")" = "Version $VERSION ($BUILD)" ]
/usr/bin/codesign --verify --deep --strict "$RELEASE_DIR/ClipboardArchive.app"
/usr/bin/codesign --verify --strict "$CLI"
"$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/check-local-only.sh" "$RELEASE_DIR" >/dev/null
(
  cd "$RELEASE_DIR"
  shasum -a 256 -c SHA256SUMS >/dev/null
)

echo "release validation ok"
echo "release_dir: $RELEASE_DIR"
