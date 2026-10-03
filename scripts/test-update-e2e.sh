#!/usr/bin/env bash
# End-to-end update test: build N and N+1 from a clean checkout, publish them
# to a file:// feed in scratch, install N the way a person would (copy it out
# of the disk image), let N's updater move it to N+1, then show that a
# tampered update and a tampered feed are both refused.
#
# Everything runs under a scratch root with a throwaway signing key and a
# test bundle identifier (app.clipboardarchive.e2etest), so nothing here can
# reach the installed app, its preferences, its stores or the keychain. No
# app is launched; only the update helper runs.
#
# usage: scripts/test-update-e2e.sh [SCRATCH_ROOT]
set -euo pipefail
export PATH="/usr/bin:/bin:/usr/sbin:/sbin:${PATH:-}"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
S="${1:-$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/clipboard-archive-update-e2e.XXXXXX")}"
mkdir -p "$S"
S="$(cd "$S" && pwd -P)"
if [ -n "$(ls -A "$S")" ]; then
  echo "scratch root must be empty: $S" >&2
  exit 2
fi
TEST_ID="app.clipboardarchive.e2etest"
APP_NAME="Clipboard Archive.app"
HELPER_REL="Contents/Helpers/Clipboard Archive Updater.app/Contents/MacOS/ClipboardArchiveUpdater"

cleanup() {
  for mount in "$S"/mnt-*; do
    [ -d "$mount" ] && /usr/bin/hdiutil detach -quiet "$mount" 2>/dev/null || true
  done
  # Sparkle's state for the TEST identifier only, by exact name.
  /usr/bin/defaults delete "$TEST_ID.updater" >/dev/null 2>&1 || true
  rm -rf "$HOME/Library/Caches/$TEST_ID" "$HOME/Library/Caches/$TEST_ID.updater" \
         "$HOME/Library/HTTPStorages/$TEST_ID.updater" "$HOME/Library/HTTPStorages/$TEST_ID.updater.binarycookies"
}
trap cleanup EXIT

say() { printf '\n## %s\n' "$*"; }
check() {
  if eval "$2"; then echo "PASS  $1"; else echo "FAIL  $1"; FAILED=1; fi
}
FAILED=0
version_of() { /usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "$1/Contents/Info.plist"; }

say "clean checkout of $(git -C "$ROOT" rev-parse --short HEAD)"
git clone --quiet --no-local "$ROOT" "$S/src"
git -C "$S/src" checkout --quiet "$(git -C "$ROOT" rev-parse HEAD)"
git -C "$S/src" status --short | head -5
# Nothing is copied from this checkout's .build: packages, Sparkle and its
# tools are fetched fresh (pinned by Package.resolved and a checksum).

say "throwaway Ed25519 key pair (scratch only, never the keychain)"
mkdir -p "$S/keys"
( umask 077; /usr/bin/head -c 32 /dev/urandom | /usr/bin/base64 > "$S/keys/private.txt" )
/usr/bin/xcrun swift "$ROOT/scripts/test-support/ed25519-public-key.swift" "$S/keys/private.txt" > "$S/keys/public.txt"
echo "public key: $(cat "$S/keys/public.txt")"

read -r BASE_VERSION BASE_BUILD <<<"$(cd "$S/src" && . scripts/lib/release-identity.sh && release_identity_newest CHANGELOG.md)"
N1=$((BASE_BUILD + 1000))
N2=$((BASE_BUILD + 1001))
say "test releases $BASE_VERSION build $N1 (N) and build $N2 (N+1)"
python3 - "$S/src/CHANGELOG.md" "$BASE_VERSION" "$N1" "$N2" <<'PY'
import sys
path, version, n1, n2 = sys.argv[1:]
text = open(path).read()
head, rest = text.split("\n## ", 1)
entries = (f"## {version} build {n2} - 2026-10-03\n\n- Synthetic N+1 release for the update test.\n\n"
           f"## {version} build {n1} - 2026-10-03\n\n- Synthetic N release for the update test.\n\n")
open(path, "w").write(head + "\n" + entries + "## " + rest)
PY
git -C "$S/src" -c user.name="update test" -c user.email="update-test@example.invalid" \
  commit --quiet -am "Synthetic CHANGELOG entries for the update test"

FEED="$S/feed"
mkdir -p "$FEED" "$S/tmp"
release() {
  local build="$1"; shift
  (cd "$S/src" && TMPDIR="$S/tmp" CLIPBOARD_ARCHIVE_BUNDLE_ID="$TEST_ID" ./scripts/release.sh \
    --version "$BASE_VERSION" --build "$build" --out "$S/out/$build" \
    --feed-url "file://$FEED/appcast.xml" --download-url-prefix "file://$FEED" \
    --ed-public-key-file "$S/keys/public.txt" --ed-key-file "$S/keys/private.txt" "$@")
}

say "release.sh: build N"
release "$N1" > "$S/release-$N1.log" 2>&1 || { tail -30 "$S/release-$N1.log"; exit 1; }
grep -E '^(version|commit|signing|updates|dmg|sha256|appcast|release):' "$S/release-$N1.log"
cp "$S/out/$N1/"*.dmg "$S/out/$N1/appcast.xml" "$FEED/"

say "release.sh: build N+1, added to the published appcast"
release "$N2" --appcast "$FEED/appcast.xml" > "$S/release-$N2.log" 2>&1 || { tail -30 "$S/release-$N2.log"; exit 1; }
grep -E '^(version|commit|signing|updates|dmg|sha256|appcast|release):' "$S/release-$N2.log"
cp "$S/out/$N2/"*.dmg "$S/out/$N2/appcast.xml" "$FEED/"
echo "appcast items: $(grep -c '<item>' "$FEED/appcast.xml") (versions: $(grep -o '<sparkle:version>[0-9]*' "$FEED/appcast.xml" | cut -d'>' -f2 | tr '\n' ' '))"
grep -q 'sparkle-signatures' "$FEED/appcast.xml" && echo "appcast carries its own signature"

install_n() {
  local dest="$1"
  local mount="$S/mnt-$RANDOM"
  mkdir -p "$mount" "$dest"
  /usr/bin/hdiutil attach -quiet -nobrowse -readonly -mountpoint "$mount" "$FEED/ClipboardArchive-$BASE_VERSION-build$N1.dmg"
  /usr/bin/ditto "$mount/$APP_NAME" "$dest/$APP_NAME"
  /usr/bin/hdiutil detach -quiet "$mount"
  rmdir "$mount"
}

say "disk image layout"
mount="$S/mnt-layout"; mkdir -p "$mount"
/usr/bin/hdiutil attach -quiet -nobrowse -readonly -mountpoint "$mount" "$FEED/ClipboardArchive-$BASE_VERSION-build$N1.dmg"
ls -l "$mount" | sed 1d
check "disk image holds the app and an Applications shortcut" \
  '[ -d "$mount/$APP_NAME" ] && [ "$(readlink "$mount/Applications")" = /Applications ]'
/usr/bin/hdiutil detach -quiet "$mount"; rmdir "$mount"

say "install N by copying it out of the disk image"
A="$S/Applications"
install_n "$A"
echo "installed: $(version_of "$A/$APP_NAME")"
check "installed copy is build N" '[ "$(version_of "$A/$APP_NAME")" = "$N1" ]'

say "N's own updater, unattended: N -> N+1"
set +e
"$A/$APP_NAME/$HELPER_REL" --unattended --verbose > "$S/update.out" 2> "$S/update.err"
rc=$?
set -e
sed 's/^/  stderr: /' "$S/update.err"; sed 's/^/  stdout: /' "$S/update.out"
echo "  rc=$rc"
check "updater exits 0 (installed)" '[ "$rc" -eq 0 ]'
check "installed copy is now build N+1" '[ "$(version_of "$A/$APP_NAME")" = "$N2" ]'
check "helper inside it is build N+1 too" \
  '[ "$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "$A/$APP_NAME/Contents/Helpers/Clipboard Archive Updater.app/Contents/Info.plist")" = "$N2" ]'
check "updated app passes codesign --verify --deep --strict" '/usr/bin/codesign --verify --deep --strict "$A/$APP_NAME" 2>/dev/null'
check "updated app carries no quarantine flag" '! /usr/bin/xattr -r "$A/$APP_NAME" | grep -q com.apple.quarantine'

say "second run: nothing newer"
set +e
"$A/$APP_NAME/$HELPER_REL" --unattended > "$S/update2.out" 2>&1
rc=$?
set -e
sed 's/^/  /' "$S/update2.out"; echo "  rc=$rc"
check "updater exits 5 (up to date)" '[ "$rc" -eq 5 ]'

say "tampered update: one byte appended to the N+1 disk image"
cp "$FEED/ClipboardArchive-$BASE_VERSION-build$N2.dmg" "$S/n2.dmg.good"
printf 'x' >> "$FEED/ClipboardArchive-$BASE_VERSION-build$N2.dmg"
B="$S/Applications-tampered-update"
install_n "$B"
/usr/bin/defaults delete "$TEST_ID.updater" >/dev/null 2>&1 || true
rm -rf "$HOME/Library/Caches/$TEST_ID.updater"
set +e
"$B/$APP_NAME/$HELPER_REL" --unattended > "$S/update3.out" 2>&1
rc=$?
set -e
sed 's/^/  /' "$S/update3.out"; echo "  rc=$rc"
check "tampered update is refused (exit 4)" '[ "$rc" -eq 4 ]'
check "copy stays on build N" '[ "$(version_of "$B/$APP_NAME")" = "$N1" ]'
cp "$S/n2.dmg.good" "$FEED/ClipboardArchive-$BASE_VERSION-build$N2.dmg"

say "tampered feed: the appcast edited after it was signed"
cp "$FEED/appcast.xml" "$S/appcast.good"
python3 - "$FEED/appcast.xml" <<'PY'
import sys
path = sys.argv[1]
text = open(path).read()
open(path, "w").write(text.replace("Synthetic N+1 release", "Edited N+1 release", 1))
PY
C="$S/Applications-tampered-feed"
install_n "$C"
/usr/bin/defaults delete "$TEST_ID.updater" >/dev/null 2>&1 || true
rm -rf "$HOME/Library/Caches/$TEST_ID.updater"
set +e
"$C/$APP_NAME/$HELPER_REL" --unattended > "$S/update4.out" 2>&1
rc=$?
set -e
sed 's/^/  /' "$S/update4.out"; echo "  rc=$rc"
check "tampered feed is not acted on (non-zero exit)" '[ "$rc" -ne 0 ] && [ "$rc" -ne 5 ]'
check "copy stays on build N" '[ "$(version_of "$C/$APP_NAME")" = "$N1" ]'
cp "$S/appcast.good" "$FEED/appcast.xml"

say "a copy built without a feed never checks"
(cd "$S/src" && TMPDIR="$S/tmp" CLIPBOARD_ARCHIVE_BUNDLE_ID="$TEST_ID" ./scripts/release.sh \
  --version "$BASE_VERSION" --build "$N1" --out "$S/out/nofeed") > "$S/release-nofeed.log" 2>&1
D="$S/Applications-nofeed"; mkdir -p "$D"
mount="$S/mnt-nofeed"; mkdir -p "$mount"
/usr/bin/hdiutil attach -quiet -nobrowse -readonly -mountpoint "$mount" "$S/out/nofeed/ClipboardArchive-$BASE_VERSION-build$N1.dmg"
/usr/bin/ditto "$mount/$APP_NAME" "$D/$APP_NAME"
/usr/bin/hdiutil detach -quiet "$mount"; rmdir "$mount"
set +e
"$D/$APP_NAME/$HELPER_REL" --unattended > "$S/update5.out" 2>&1
rc=$?
set -e
sed 's/^/  /' "$S/update5.out"; echo "  rc=$rc"
check "no-feed copy exits 3 (not set up) without a request" '[ "$rc" -eq 3 ]'

say "result"
if [ "$FAILED" -eq 0 ]; then
  echo "update e2e ok: build $N1 -> $N2 installed by the app's own updater; tampering refused"
  echo "scratch: $S"
else
  echo "update e2e FAILED; scratch kept at $S" >&2
  exit 1
fi
