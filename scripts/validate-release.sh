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
"$RELEASE_DIR/bin/clipboard-archive" self-test >/dev/null
"$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/check-local-only.sh" "$RELEASE_DIR" >/dev/null
(
  cd "$RELEASE_DIR"
  shasum -a 256 -c SHA256SUMS >/dev/null
)

echo "release validation ok"
echo "release_dir: $RELEASE_DIR"
