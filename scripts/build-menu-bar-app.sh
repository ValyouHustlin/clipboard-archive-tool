#!/usr/bin/env bash
set -euo pipefail
export PATH="/usr/bin:/bin:/usr/sbin:/sbin:${PATH:-}"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_NAME="ClipboardArchive"
# shellcheck source=lib/release-identity.sh
. "$ROOT/scripts/lib/release-identity.sh"
read -r CHANGELOG_VERSION CHANGELOG_BUILD <<<"$(release_identity_newest "$ROOT/CHANGELOG.md")"
VERSION="${CLIPBOARD_ARCHIVE_VERSION:-$CHANGELOG_VERSION}"
BUILD_NUMBER="${CLIPBOARD_ARCHIVE_BUILD:-$CHANGELOG_BUILD}"
if [ -z "$VERSION" ] || [ -z "$BUILD_NUMBER" ]; then
  echo "no release identity: CHANGELOG.md has no '## <version> build <n> - <date>' entry" >&2
  exit 1
fi
APP_DIR="${CLIPBOARD_ARCHIVE_APP_OUTPUT:-$ROOT/dist/${APP_NAME}.app}"
# Tests that install a copy beside the real app use their own identifier, so
# nothing keyed on the identifier (preferences, the updater's state, a quit
# event from an installer) can reach the real one.
BUNDLE_ID="${CLIPBOARD_ARCHIVE_BUNDLE_ID:-app.clipboardarchive}"
case "$BUNDLE_ID" in
  app.clipboardarchive|app.clipboardarchive.*) ;;
  *) echo "bundle identifier must be app.clipboardarchive or below it: $BUNDLE_ID" >&2; exit 1 ;;
esac
CONTENTS="$APP_DIR/Contents"
MACOS="$CONTENTS/MacOS"
RESOURCES="$CONTENTS/Resources"

cd "$ROOT"
/usr/bin/xcrun swift build -c release --product ClipboardArchiveMenuBar

case "$APP_DIR" in
  ""|"/"|"$HOME"|"$ROOT"|"$ROOT/dist")
    echo "refusing unsafe app output path: $APP_DIR" >&2
    exit 1
    ;;
  *.app)
    ;;
  *)
    echo "app output must end in .app: $APP_DIR" >&2
    exit 1
    ;;
esac

rm -rf "$APP_DIR"
mkdir -p "$MACOS" "$RESOURCES"
cp "$ROOT/.build/release/ClipboardArchiveMenuBar" "$MACOS/$APP_NAME"

cat > "$CONTENTS/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
 "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key>
  <string>ClipboardArchive</string>
  <key>CFBundleIdentifier</key>
  <string>$BUNDLE_ID</string>
  <key>CFBundleName</key>
  <string>Clipboard Archive</string>
  <key>CFBundleDisplayName</key>
  <string>Clipboard Archive</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleShortVersionString</key>
  <string>$VERSION</string>
  <key>CFBundleVersion</key>
  <string>$BUILD_NUMBER</string>
  <key>LSMinimumSystemVersion</key>
  <string>13.0</string>
  <key>LSUIElement</key>
  <true/>
  <key>NSHumanReadableCopyright</key>
  <string>Local-first clipboard archive.</string>
</dict>
</plist>
PLIST

if command -v codesign >/dev/null 2>&1; then
  codesign --force --sign - "$APP_DIR" >/dev/null
fi

echo "$APP_DIR"
