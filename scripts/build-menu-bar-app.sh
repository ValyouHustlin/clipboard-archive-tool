#!/usr/bin/env bash
set -euo pipefail
export PATH="/usr/bin:/bin:/usr/sbin:/sbin:${PATH:-}"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_NAME="ClipboardArchive"
VERSION="${CLIPBOARD_ARCHIVE_VERSION:-0.1.2}"
BUILD_NUMBER="${CLIPBOARD_ARCHIVE_BUILD:-4}"
APP_DIR="${CLIPBOARD_ARCHIVE_APP_OUTPUT:-$ROOT/dist/${APP_NAME}.app}"
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
  <string>app.clipboardarchive</string>
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
