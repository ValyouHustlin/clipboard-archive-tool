#!/usr/bin/env bash
# Build a Clipboard Archive release: the app with its update helper, a
# drag-to-Applications disk image, its checksum, release notes from the
# CHANGELOG, and (when a feed is set up) a signed appcast entry.
#
# Default: ad hoc signed, no update feed (the updater stays dormant).
# Developer ID signing, hardened runtime, notarization and stapling sit
# behind --sign developer-id and --notarize, and refuse before building when
# the identity or the notary profile is not on this Mac.
#
# Nothing here publishes anything. The output is a folder; putting the disk
# image and the appcast where people can download them is a separate step.
set -euo pipefail
export PATH="/usr/bin:/bin:/usr/sbin:/sbin:${PATH:-}"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib/release-identity.sh
. "$ROOT/scripts/lib/release-identity.sh"

SPARKLE_VERSION="2.10.0"
SPARKLE_TOOLS_SHA256="c2bf58aa8387266ac179357b1415d6f2635f044da8be41042af32425dae6da0c"
APP_DISPLAY_NAME="Clipboard Archive"
HELPER_NAME="Clipboard Archive Updater"
SECURITY_BIN="${CLIPBOARD_ARCHIVE_SECURITY_BIN:-/usr/bin/security}"
# Overridable so the refusal can be tested without Apple credentials.
if [ -n "${CLIPBOARD_ARCHIVE_NOTARYTOOL:-}" ]; then
  NOTARYTOOL=("$CLIPBOARD_ARCHIVE_NOTARYTOOL")
else
  NOTARYTOOL=(/usr/bin/xcrun notarytool)
fi

usage() {
  cat <<'USAGE'
usage: scripts/release.sh [options]

  --version X.Y.Z          default: the newest "## X.Y.Z build N - date" in CHANGELOG.md
  --build N                default: the build number of that same entry
  --out DIR                default: releases/<version>-build<N>
  --sign adhoc|developer-id
                           default: adhoc
  --identity NAME          the Developer ID identity to use (default: the only
                           "Developer ID Application" identity in the keychain)
  --notarize               notarize and staple; needs --sign developer-id and
                           --notary-profile (or CLIPBOARD_ARCHIVE_NOTARY_PROFILE),
                           a profile saved with `xcrun notarytool store-credentials`
  --feed-url URL           build the updater in, pointed at this appcast
                           (https; http://127.0.0.1 or localhost only for a local test)
  --ed-public-key-file F   the update signing public key (base64); default:
                           release/update-signing-public-key.txt
  --ed-key-file F          private key file used to sign the update and the
                           appcast; default: the login-keychain account below
  --ed-key-account NAME    Sparkle login-keychain account holding the private
                           key (default: clipboard-archive)
  --download-url-prefix U  where the disk image will be published; with
                           --feed-url this writes the appcast
  --appcast FILE           an existing appcast to add this release to
  --allow-dirty            build from uncommitted changes (the release says so)
  --preflight-only         run every check that does not need a build, then stop
  --fetch-sparkle-tools    download Sparkle's generate_keys and sign_update
                           (pinned, checksum-verified) to .build/sparkle-tools, then stop
  -h, --help               this text

Exit codes: 0 built, 1 failed, 2 usage, 3 refused (a precondition is missing).
USAGE
}

die() { echo "release: $*" >&2; exit 1; }
refuse() { echo "release refused: $*" >&2; exit 3; }
step() { echo "== $*"; }

VERSION=""; BUILD=""; OUT=""; SIGN="adhoc"; IDENTITY=""; NOTARIZE=false
NOTARY_PROFILE="${CLIPBOARD_ARCHIVE_NOTARY_PROFILE:-}"; FEED_URL=""
ED_PUBLIC_KEY_FILE="$ROOT/release/update-signing-public-key.txt"; ED_PUBLIC_KEY_FILE_SET=false
ED_KEY_FILE=""; DOWNLOAD_PREFIX=""; EXISTING_APPCAST=""; ALLOW_DIRTY=false; PREFLIGHT_ONLY=false
FETCH_TOOLS_ONLY=false
ED_KEY_ACCOUNT="clipboard-archive"

need_value() { [ "$#" -ge 2 ] && [ -n "$2" ] || { echo "release: $1 needs a value" >&2; usage >&2; exit 2; }; }
while [ "$#" -gt 0 ]; do
  case "$1" in
    --version) need_value "$@"; VERSION="$2"; shift 2 ;;
    --build) need_value "$@"; BUILD="$2"; shift 2 ;;
    --out) need_value "$@"; OUT="$2"; shift 2 ;;
    --sign) need_value "$@"; SIGN="$2"; shift 2 ;;
    --identity) need_value "$@"; IDENTITY="$2"; shift 2 ;;
    --notarize) NOTARIZE=true; shift ;;
    --notary-profile) need_value "$@"; NOTARY_PROFILE="$2"; shift 2 ;;
    --feed-url) need_value "$@"; FEED_URL="$2"; shift 2 ;;
    --ed-public-key-file) need_value "$@"; ED_PUBLIC_KEY_FILE="$2"; ED_PUBLIC_KEY_FILE_SET=true; shift 2 ;;
    --ed-key-file) need_value "$@"; ED_KEY_FILE="$2"; shift 2 ;;
    --ed-key-account) need_value "$@"; ED_KEY_ACCOUNT="$2"; shift 2 ;;
    --download-url-prefix) need_value "$@"; DOWNLOAD_PREFIX="$2"; shift 2 ;;
    --appcast) need_value "$@"; EXISTING_APPCAST="$2"; shift 2 ;;
    --allow-dirty) ALLOW_DIRTY=true; shift ;;
    --preflight-only) PREFLIGHT_ONLY=true; shift ;;
    --fetch-sparkle-tools) FETCH_TOOLS_ONLY=true; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "release: unknown option: $1" >&2; usage >&2; exit 2 ;;
  esac
done

case "$SIGN" in
  adhoc|developer-id) ;;
  *) echo "release: --sign must be adhoc or developer-id, not '$SIGN'" >&2; exit 2 ;;
esac

# A URL an update may come from: HTTPS, or plain HTTP to this Mac only.
# No user-info part, which could hide the real host behind a loopback name.
acceptable_url() {
  case "$1" in
    *@*) return 1 ;;
    https://?*|http://127.0.0.1|http://127.0.0.1[:/]*|http://localhost|http://localhost[:/]*) return 0 ;;
    *) return 1 ;;
  esac
}

# Sparkle's command-line tools (generate_keys, sign_update), pinned by
# version and checksum, fetched once into .build.
TOOLS="${CLIPBOARD_ARCHIVE_SPARKLE_TOOLS:-$ROOT/.build/sparkle-tools/$SPARKLE_VERSION}"
fetch_sparkle_tools() {
  # The pinned archive is kept and re-hashed on every use, and the tools are
  # unpacked from it each time, so a changed file in the cache is never run.
  local archive="$TOOLS/Sparkle-$SPARKLE_VERSION.tar.xz"
  if [ ! -f "$archive" ] || ! echo "$SPARKLE_TOOLS_SHA256  $archive" | /usr/bin/shasum -a 256 -c - >/dev/null 2>&1; then
    mkdir -p "$TOOLS"
    rm -f "$archive"
    /usr/bin/curl -fsSL -o "$archive.part" \
      "https://github.com/sparkle-project/Sparkle/releases/download/$SPARKLE_VERSION/Sparkle-$SPARKLE_VERSION.tar.xz"
    echo "$SPARKLE_TOOLS_SHA256  $archive.part" | /usr/bin/shasum -a 256 -c - >/dev/null \
      || { rm -f "$archive.part"; die "Sparkle $SPARKLE_VERSION tools download does not match its pinned checksum"; }
    mv "$archive.part" "$archive"
  fi
  rm -rf "$TOOLS/bin"
  /usr/bin/tar -xf "$archive" -C "$TOOLS" bin
}

if $FETCH_TOOLS_ONLY; then
  fetch_sparkle_tools
  echo "sparkle tools: $TOOLS/bin"
  exit 0
fi

# --- Preflight: everything that can refuse does so before anything is built.

step "preflight"
for tool in /usr/bin/xcrun /usr/bin/codesign /usr/bin/hdiutil /usr/bin/plutil /usr/bin/shasum /usr/bin/ditto /usr/bin/python3 /usr/bin/git; do
  [ -x "$tool" ] || refuse "missing tool $tool"
done

read -r NEWEST_VERSION NEWEST_BUILD <<<"$(release_identity_newest "$ROOT/CHANGELOG.md")"
VERSION="${VERSION:-$NEWEST_VERSION}"
BUILD="${BUILD:-$NEWEST_BUILD}"
case "$VERSION" in *[!0-9.]*|"") refuse "invalid version '$VERSION'" ;; esac
case "$BUILD" in *[!0-9]*|"") refuse "invalid build number '$BUILD'" ;; esac
release_identity_has_entry "$ROOT/CHANGELOG.md" "$VERSION" "$BUILD" \
  || refuse "CHANGELOG.md has no '## $VERSION build $BUILD - <date>' entry; the release notes come from it"
echo "version: $VERSION (build $BUILD)"

COMMIT="$(/usr/bin/git -C "$ROOT" rev-parse HEAD)"
DIRTY=false
if [ -n "$(/usr/bin/git -C "$ROOT" status --porcelain --untracked-files=normal)" ]; then
  DIRTY=true
  $ALLOW_DIRTY || refuse "the working tree has uncommitted changes; commit them or pass --allow-dirty"
fi
echo "commit: $COMMIT$($DIRTY && echo ' (DIRTY)')"

if [ "$SIGN" = "developer-id" ]; then
  identities="$("$SECURITY_BIN" find-identity -v -p codesigning 2>/dev/null || true)"
  developer_ids="$(printf '%s\n' "$identities" | /usr/bin/sed -n 's/^ *[0-9][0-9]*) [0-9A-F]\{40\} "\(Developer ID Application: .*\)"$/\1/p')"
  if [ -z "$developer_ids" ]; then
    refuse "--sign developer-id needs a 'Developer ID Application' certificate, and this keychain has none.
  'security find-identity -v -p codesigning' lists no Developer ID Application identity.
  Create one from an Apple Developer Program account (Certificates, Identifiers & Profiles >
  Developer ID Application), install it in the login keychain, then run this again.
  Nothing was built or signed. An ad hoc release still works: drop --sign developer-id."
  fi
  if [ -z "$IDENTITY" ]; then
    count="$(printf '%s\n' "$developer_ids" | /usr/bin/grep -c .)"
    [ "$count" -eq 1 ] || refuse "this keychain has $count Developer ID Application identities; pick one with --identity"
    IDENTITY="$developer_ids"
  else
    printf '%s\n' "$developer_ids" | /usr/bin/grep -Fqx "$IDENTITY" \
      || refuse "identity '$IDENTITY' is not a valid Developer ID Application identity in this keychain"
  fi
  echo "signing: $IDENTITY (hardened runtime, secure timestamp)"
else
  echo "signing: ad hoc (Gatekeeper will not trust this copy on another Mac)"
fi

if $NOTARIZE; then
  [ "$SIGN" = "developer-id" ] || refuse "--notarize needs --sign developer-id; Apple does not notarize ad hoc signatures"
  [ -n "$NOTARY_PROFILE" ] || refuse "--notarize needs --notary-profile NAME (saved with 'xcrun notarytool store-credentials NAME')"
  "${NOTARYTOOL[@]}" --help >/dev/null 2>&1 || refuse "notarytool is not installed (Xcode command line tools)"
  # Asking for the history proves the saved profile exists and its
  # credentials work, before an hour of building finds out at submit.
  "${NOTARYTOOL[@]}" history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1 \
    || refuse "notary profile '$NOTARY_PROFILE' is not usable ('notarytool history' failed).
  Save it with 'xcrun notarytool store-credentials $NOTARY_PROFILE', then run this again."
  echo "notarize: profile $NOTARY_PROFILE"
fi

ED_PUBLIC_KEY=""
if [ -n "$FEED_URL" ]; then
  acceptable_url "$FEED_URL" \
    || refuse "--feed-url must be https:// (or http://127.0.0.1 / localhost for a local test): $FEED_URL"
  [ -z "$DOWNLOAD_PREFIX" ] || acceptable_url "$DOWNLOAD_PREFIX" \
    || refuse "--download-url-prefix must be https:// (or http://127.0.0.1 / localhost for a local test): $DOWNLOAD_PREFIX"
  [ -f "$ED_PUBLIC_KEY_FILE" ] || refuse "--feed-url needs the update signing public key; '$ED_PUBLIC_KEY_FILE' does not exist.
  Create the key once with Sparkle's generate_keys (it stays in the login keychain) and save
  the public half there, or pass --ed-public-key-file."
  ED_PUBLIC_KEY="$(/usr/bin/tr -d ' \n\r\t' < "$ED_PUBLIC_KEY_FILE")"
  decoded_bytes="$(printf '%s' "$ED_PUBLIC_KEY" | /usr/bin/base64 -D 2>/dev/null | /usr/bin/wc -c | /usr/bin/tr -d ' ')"
  [ "$decoded_bytes" = "32" ] || refuse "'$ED_PUBLIC_KEY_FILE' is not a base64 Ed25519 public key (32 bytes)"
  echo "updates: feed $FEED_URL"
  if [ -n "$DOWNLOAD_PREFIX" ]; then
    # The key that will sign must be the key every copy is built to trust:
    # a mismatch would ship copies that refuse every update they are sent.
    if [ -n "$ED_KEY_FILE" ]; then
      [ -f "$ED_KEY_FILE" ] || refuse "--ed-key-file '$ED_KEY_FILE' does not exist"
      signer_public="$(/usr/bin/xcrun swift "$ROOT/scripts/lib/ed25519-public-key.swift" "$ED_KEY_FILE" 2>/dev/null || true)"
    else
      fetch_sparkle_tools
      signer_public="$("$TOOLS/bin/generate_keys" -p --account "$ED_KEY_ACCOUNT" 2>/dev/null)" || signer_public=""
      signer_public="$(printf '%s' "$signer_public" | /usr/bin/tail -1 | /usr/bin/tr -d ' \n\r\t')"
    fi
    [ -n "$signer_public" ] || refuse "could not read the update signing key (--ed-key-file, or Sparkle's login-keychain item)"
    [ "$signer_public" = "$ED_PUBLIC_KEY" ] || refuse "the update signing key does not match '$ED_PUBLIC_KEY_FILE'.
  Copies built with that public key would refuse every update this key signs."
    echo "updates: signing key matches the public key built in"
  fi
  [ -n "$DOWNLOAD_PREFIX" ] && echo "updates: disk image will be served from $DOWNLOAD_PREFIX"
  [ -z "$EXISTING_APPCAST" ] || [ -f "$EXISTING_APPCAST" ] || refuse "--appcast '$EXISTING_APPCAST' does not exist"
else
  $ED_PUBLIC_KEY_FILE_SET && refuse "--ed-public-key-file without --feed-url builds a key into an app that never checks"
  [ -z "$DOWNLOAD_PREFIX" ] || refuse "--download-url-prefix without --feed-url writes an appcast nothing reads"
  echo "updates: none (no --feed-url; the updater in this copy stays dormant)"
fi

BUNDLE_ID="${CLIPBOARD_ARCHIVE_BUNDLE_ID:-app.clipboardarchive}"
[ "$BUNDLE_ID" = "app.clipboardarchive" ] || echo "TEST BUILD: bundle identifier $BUNDLE_ID"

if $PREFLIGHT_ONLY; then
  echo "preflight ok"
  exit 0
fi

# --- Build

OUT="${OUT:-$ROOT/releases/$VERSION-build$BUILD}"
case "$OUT" in ""|"/"|"$HOME"|"$ROOT") die "refusing output directory '$OUT'" ;; esac
mkdir -p "$OUT"
OUT="$(cd "$OUT" && pwd)"
WORK="$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/clipboard-archive-release.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
APP="$WORK/stage/$APP_DISPLAY_NAME.app"
HELPER="$APP/Contents/Helpers/$HELPER_NAME.app"
DMG_NAME="ClipboardArchive-$VERSION-build$BUILD.dmg"
DMG="$OUT/$DMG_NAME"

step "build"
cd "$ROOT"
/usr/bin/xcrun swift build -c release --product ClipboardArchiveUpdater
CLIPBOARD_ARCHIVE_VERSION="$VERSION" CLIPBOARD_ARCHIVE_BUILD="$BUILD" CLIPBOARD_ARCHIVE_APP_OUTPUT="$APP" \
  CLIPBOARD_ARCHIVE_BUNDLE_ID="$BUNDLE_ID" "$ROOT/scripts/build-menu-bar-app.sh" >/dev/null

BIN_DIR="$(/usr/bin/xcrun swift build -c release --show-bin-path)"
SPARKLE_FRAMEWORK="$BIN_DIR/Sparkle.framework"
[ -d "$SPARKLE_FRAMEWORK" ] || die "Sparkle.framework is not beside the release build at $SPARKLE_FRAMEWORK"

step "assemble the update helper"
mkdir -p "$HELPER/Contents/MacOS" "$HELPER/Contents/Frameworks"
cp "$BIN_DIR/ClipboardArchiveUpdater" "$HELPER/Contents/MacOS/ClipboardArchiveUpdater"
/usr/bin/ditto "$SPARKLE_FRAMEWORK" "$HELPER/Contents/Frameworks/Sparkle.framework"
# Not sandboxed, so Sparkle's XPC services are dead weight and extra
# signatures to keep right. Sparkle documents removing them in this case.
rm -rf "$HELPER/Contents/Frameworks/Sparkle.framework/Versions/B/XPCServices" \
       "$HELPER/Contents/Frameworks/Sparkle.framework/XPCServices"
cat > "$HELPER/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key><string>ClipboardArchiveUpdater</string>
  <key>CFBundleIdentifier</key><string>$BUNDLE_ID.updater</string>
  <key>CFBundleName</key><string>$HELPER_NAME</string>
  <key>CFBundleDisplayName</key><string>$HELPER_NAME</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$BUILD</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>LSUIElement</key><true/>
  <key>NSPrincipalClass</key><string>NSApplication</string>
  <key>ClipboardArchiveHostBundleIdentifier</key><string>$BUNDLE_ID</string>
  <!-- Plain HTTP only to this Mac, for the local update test. -->
  <key>NSAppTransportSecurity</key><dict><key>NSAllowsLocalNetworking</key><true/></dict>
</dict>
</plist>
PLIST
/usr/bin/plutil -lint "$HELPER/Contents/Info.plist" >/dev/null

step "update settings in the app's Info.plist"
INFO="$APP/Contents/Info.plist"
pb() { /usr/libexec/PlistBuddy -c "$1" "$INFO" >/dev/null; }
# Always: an update request never describes the machine it comes from.
pb "Add :SUEnableSystemProfiling bool false"
pb "Add :SUDefaultsDomain string $BUNDLE_ID.updates"
if [ -n "$FEED_URL" ]; then
  pb "Add :SUFeedURL string $FEED_URL"
  pb "Add :SUPublicEDKey string $ED_PUBLIC_KEY"
  pb "Add :SURequireSignedFeed bool true"
  pb "Add :SUVerifyUpdateBeforeExtraction bool true"
  # Never fall back to parsing an unverified feed (the library's default is
  # to do so 20 days after the first bad signature).
  pb "Add :SUSignedFeedFailureExpirationInterval integer 0"
fi
/usr/bin/plutil -lint "$INFO" >/dev/null

step "sign ($SIGN)"
if [ "$SIGN" = "developer-id" ]; then
  SIGN_ARGS=(--force --options runtime --timestamp --sign "$IDENTITY")
else
  SIGN_ARGS=(--force --sign -)
fi
FRAMEWORK="$HELPER/Contents/Frameworks/Sparkle.framework"
# Inside out: Sparkle's own helpers, the framework, the updater, the app.
/usr/bin/codesign "${SIGN_ARGS[@]}" "$FRAMEWORK/Versions/B/Autoupdate"
/usr/bin/codesign "${SIGN_ARGS[@]}" "$FRAMEWORK/Versions/B/Updater.app"
/usr/bin/codesign "${SIGN_ARGS[@]}" "$FRAMEWORK"
/usr/bin/codesign "${SIGN_ARGS[@]}" "$HELPER"
/usr/bin/codesign "${SIGN_ARGS[@]}" "$APP"
/usr/bin/codesign --verify --deep --strict "$APP"
echo "codesign verify: ok"

step "boundary: the app that reads the clipboard has no network code"
"$ROOT/scripts/check-local-only.sh" --app "$APP"

step "leak scan"
NOTES_MD="$OUT/release-notes.md"
NOTES_HTML="$OUT/release-notes.html"
/usr/bin/python3 "$ROOT/scripts/release_tools.py" notes "$ROOT/CHANGELOG.md" "$VERSION" "$BUILD" --md "$NOTES_MD" --html "$NOTES_HTML"
/usr/bin/python3 "$ROOT/scripts/release_tools.py" leak-scan \
  "$APP/Contents/MacOS/ClipboardArchive" "$INFO" \
  "$HELPER/Contents/MacOS/ClipboardArchiveUpdater" "$HELPER/Contents/Info.plist" \
  "$NOTES_MD" "$NOTES_HTML"

if $NOTARIZE; then
  step "notarize the app"
  /usr/bin/ditto -c -k --keepParent "$APP" "$WORK/app.zip"
  "${NOTARYTOOL[@]}" submit "$WORK/app.zip" --keychain-profile "$NOTARY_PROFILE" --wait
  /usr/bin/xcrun stapler staple "$APP"
fi

step "disk image"
mkdir -p "$WORK/dmg"
/usr/bin/ditto "$APP" "$WORK/dmg/$APP_DISPLAY_NAME.app"
ln -s /Applications "$WORK/dmg/Applications"
rm -f "$DMG"
/usr/bin/hdiutil create -quiet -volname "$APP_DISPLAY_NAME $VERSION" -srcfolder "$WORK/dmg" \
  -fs HFS+ -format UDZO -ov "$DMG"
if [ "$SIGN" = "developer-id" ]; then
  /usr/bin/codesign --force --timestamp --sign "$IDENTITY" "$DMG"
fi
if $NOTARIZE; then
  step "notarize the disk image"
  "${NOTARYTOOL[@]}" submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
  /usr/bin/xcrun stapler staple "$DMG"
fi
/usr/bin/hdiutil verify -quiet "$DMG"
(cd "$OUT" && /usr/bin/shasum -a 256 "$DMG_NAME" > "$DMG_NAME.sha256")
DMG_SHA256="$(/usr/bin/cut -d' ' -f1 < "$DMG.sha256")"
DMG_BYTES="$(/usr/bin/stat -f %z "$DMG")"
echo "dmg: $DMG"
echo "sha256: $DMG_SHA256"

APPCAST=""
if [ -n "$FEED_URL" ] && [ -n "$DOWNLOAD_PREFIX" ]; then
  step "appcast"
  fetch_sparkle_tools
  KEY_ARGS=(--account "$ED_KEY_ACCOUNT")
  [ -n "$ED_KEY_FILE" ] && KEY_ARGS=(--ed-key-file "$ED_KEY_FILE")
  signature_line="$("$TOOLS/bin/sign_update" ${KEY_ARGS[@]+"${KEY_ARGS[@]}"} "$DMG")"
  ED_SIGNATURE="$(printf '%s' "$signature_line" | /usr/bin/sed -n 's/.*sparkle:edSignature="\([^"]*\)".*/\1/p')"
  [ -n "$ED_SIGNATURE" ] || die "sign_update returned no signature"
  # Belt and braces: the signature verifies (the key match was proven in preflight).
  "$TOOLS/bin/sign_update" --verify ${KEY_ARGS[@]+"${KEY_ARGS[@]}"} "$DMG" "$ED_SIGNATURE" >/dev/null \
    || die "the update signature does not verify"
  APPCAST="$OUT/appcast.xml"
  APPCAST_ARGS=()
  [ -n "$EXISTING_APPCAST" ] && APPCAST_ARGS=(--existing "$EXISTING_APPCAST")
  /usr/bin/python3 "$ROOT/scripts/release_tools.py" appcast --out "$APPCAST" ${APPCAST_ARGS[@]+"${APPCAST_ARGS[@]}"} \
    --version "$BUILD" --short "$VERSION" --url "${DOWNLOAD_PREFIX%/}/$DMG_NAME" \
    --length "$DMG_BYTES" --ed-signature "$ED_SIGNATURE" --notes-html "$NOTES_HTML"
  # The app requires a signed feed: sign_update embeds the signature in it.
  "$TOOLS/bin/sign_update" ${KEY_ARGS[@]+"${KEY_ARGS[@]}"} --disable-signing-warning "$APPCAST" >/dev/null
  /usr/bin/python3 "$ROOT/scripts/release_tools.py" leak-scan "$APPCAST"
  echo "appcast: $APPCAST"
fi

step "manifest"
R_VERSION="$VERSION" R_BUILD="$BUILD" R_COMMIT="$COMMIT" R_DIRTY="$DIRTY" R_BUNDLE_ID="$BUNDLE_ID" \
R_SIGN="$SIGN" R_NOTARIZED="$NOTARIZE" R_FEED="$FEED_URL" R_DMG="$DMG_NAME" R_SHA="$DMG_SHA256" \
R_BYTES="$DMG_BYTES" R_APPCAST="$APPCAST" R_SPARKLE="$SPARKLE_VERSION" \
/usr/bin/python3 -c '
import json, os, sys
e = os.environ
json.dump({
    "name": "Clipboard Archive",
    "version": e["R_VERSION"],
    "build": e["R_BUILD"],
    "commit": e["R_COMMIT"],
    "dirty": e["R_DIRTY"] == "true",
    "bundleIdentifier": e["R_BUNDLE_ID"],
    "signing": e["R_SIGN"],
    "notarized": e["R_NOTARIZED"] == "true",
    "updateFeed": e["R_FEED"] or None,
    "dmg": e["R_DMG"],
    "dmgSha256": e["R_SHA"],
    "dmgBytes": int(e["R_BYTES"]),
    "appcast": "appcast.xml" if e["R_APPCAST"] else None,
    "sparkle": e["R_SPARKLE"],
}, open(sys.argv[1], "w"), indent=2)
' "$OUT/release.json"
echo "release: $OUT"
