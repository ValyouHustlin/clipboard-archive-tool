#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERSION="${CLIPBOARD_ARCHIVE_VERSION:-0.1.2}"
BUILD_NUMBER="${CLIPBOARD_ARCHIVE_BUILD:-4}"
ARCH="$(uname -m)"
NAME="ClipboardArchive-${VERSION}-macos-${ARCH}"
RELEASE_ROOT="$ROOT/releases"
STAGE="$RELEASE_ROOT/$NAME"
ARCHIVE="$RELEASE_ROOT/$NAME.tar.gz"
ZIP="$RELEASE_ROOT/$NAME.zip"

cd "$ROOT"
CLIPBOARD_ARCHIVE_VERSION="$VERSION" CLIPBOARD_ARCHIVE_BUILD="$BUILD_NUMBER" ./scripts/build-menu-bar-app.sh >/dev/null
swift build -c release --product clipboard-archive >/dev/null

rm -rf "$STAGE" "$ARCHIVE" "$ZIP"
mkdir -p "$STAGE/docs" "$STAGE/bin"

cp -R "$ROOT/dist/ClipboardArchive.app" "$STAGE/ClipboardArchive.app"
cp "$ROOT/.build/release/clipboard-archive" "$STAGE/bin/clipboard-archive"
cp "$ROOT/scripts/install-release.sh" "$STAGE/install.sh"
cp "$ROOT/scripts/uninstall-release.sh" "$STAGE/uninstall.sh"
cp "$ROOT/README.md" "$STAGE/README.md"
cp "$ROOT/LICENSE" "$STAGE/LICENSE"
cp "$ROOT/PRIVACY.md" "$STAGE/PRIVACY.md"
cp "$ROOT/SECURITY.md" "$STAGE/SECURITY.md"
cp "$ROOT/CHANGELOG.md" "$STAGE/CHANGELOG.md"
cp "$ROOT/docs/INSTALL.md" "$STAGE/docs/INSTALL.md"
cp "$ROOT/docs/DISTRIBUTION.md" "$STAGE/docs/DISTRIBUTION.md"
cp "$ROOT/docs/UPDATES.md" "$STAGE/docs/UPDATES.md"
cp "$ROOT/docs/GITHUB.md" "$STAGE/docs/GITHUB.md"
chmod +x "$STAGE/install.sh" "$STAGE/uninstall.sh" "$STAGE/bin/clipboard-archive"

cat > "$STAGE/VERSION" <<VERSION
$VERSION
VERSION

cat > "$STAGE/manifest.json" <<MANIFEST
{
  "name": "Clipboard Archive",
  "version": "$VERSION",
  "build": "$BUILD_NUMBER",
  "platform": "macOS",
  "arch": "$ARCH",
  "bundleIdentifier": "app.clipboardarchive",
  "app": "ClipboardArchive.app",
  "cli": "bin/clipboard-archive",
  "installer": "install.sh",
  "archiveFormatVersion": 1
}
MANIFEST

(
  cd "$STAGE"
  find . -type f -not -name SHA256SUMS -print0 | sort -z | xargs -0 shasum -a 256 > SHA256SUMS
)

tar -C "$RELEASE_ROOT" -czf "$ARCHIVE" "$NAME"
ditto -c -k --keepParent "$STAGE" "$ZIP"

echo "release_dir: $STAGE"
echo "tarball: $ARCHIVE"
echo "zip: $ZIP"
