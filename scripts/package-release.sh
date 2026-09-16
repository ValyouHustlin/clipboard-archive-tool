#!/usr/bin/env bash
set -euo pipefail
export PATH="/usr/bin:/bin:/usr/sbin:/sbin:${PATH:-}"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERSION="${CLIPBOARD_ARCHIVE_VERSION:-0.3.0}"
BUILD_NUMBER="${CLIPBOARD_ARCHIVE_BUILD:-8}"
ARCH="$(uname -m)"
NAME="ClipboardArchive-${VERSION}-macos-${ARCH}"
RELEASE_ROOT="$ROOT/releases"
STAGE="$RELEASE_ROOT/$NAME"
ARCHIVE="$RELEASE_ROOT/$NAME.tar.gz"
ZIP="$RELEASE_ROOT/$NAME.zip"
PACKAGE_APP="$ROOT/.build/clipboard-archive-package/ClipboardArchive.app"

cd "$ROOT"
CLIPBOARD_ARCHIVE_VERSION="$VERSION" \
CLIPBOARD_ARCHIVE_BUILD="$BUILD_NUMBER" \
CLIPBOARD_ARCHIVE_APP_OUTPUT="$PACKAGE_APP" \
  ./scripts/build-menu-bar-app.sh >/dev/null
# Embed identity in the standalone executable; it must survive installation
# away from the app and must never borrow a neighboring bundle's version.
CLI_PLIST="$ROOT/.build/clipboard-archive-package/CLI-Info.plist"
case "$VERSION" in
  *[!0-9.]*|"") echo "invalid release version" >&2; exit 1 ;;
esac
case "$BUILD_NUMBER" in
  *[!0-9]*|"") echo "invalid build number" >&2; exit 1 ;;
esac
cat > "$CLI_PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>app.clipboardarchive.cli</string>
<key>CFBundleExecutable</key><string>clipboard-archive</string>
<key>CFBundleName</key><string>Clipboard Archive CLI</string>
<key>CFBundlePackageType</key><string>TOOL</string>
<key>CFBundleShortVersionString</key><string>$VERSION</string>
<key>CFBundleVersion</key><string>$BUILD_NUMBER</string>
</dict></plist>
PLIST
# SwiftPM does not track the contents of linker input files: force relinking
# when packaging a new version with the same plist pathname.
rm -f "$ROOT/.build/release/clipboard-archive"
/usr/bin/xcrun swift build -c release --product clipboard-archive \
  -Xlinker -sectcreate -Xlinker __TEXT -Xlinker __info_plist -Xlinker "$CLI_PLIST" >/dev/null
/usr/bin/codesign --force --sign - "$ROOT/.build/release/clipboard-archive" >/dev/null

rm -rf "$STAGE" "$ARCHIVE" "$ZIP"
mkdir -p "$STAGE/docs" "$STAGE/bin"

cp -R "$PACKAGE_APP" "$STAGE/ClipboardArchive.app"
cp "$ROOT/.build/release/clipboard-archive" "$STAGE/bin/clipboard-archive"
cp "$ROOT/scripts/install-release.sh" "$STAGE/install.sh"
cp "$ROOT/scripts/uninstall-release.sh" "$STAGE/uninstall.sh"
cp "$ROOT/README.md" "$STAGE/README.md"
cp "$ROOT/LICENSE" "$STAGE/LICENSE"
cp "$ROOT/PRIVACY.md" "$STAGE/PRIVACY.md"
cp "$ROOT/SECURITY.md" "$STAGE/SECURITY.md"
cp "$ROOT/CHANGELOG.md" "$STAGE/CHANGELOG.md"
cp "$ROOT/docs/CLI.md" "$STAGE/docs/CLI.md"
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
