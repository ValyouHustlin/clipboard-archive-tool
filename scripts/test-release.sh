#!/usr/bin/env bash
# Checks for scripts/release.sh and its helpers that need no build: every
# refusal, the release notes, the leak scan, and the local-only gate's
# package-graph rules. Runs in a scratch clone of HEAD.
#
# usage: scripts/test-release.sh
set -euo pipefail
export PATH="/usr/bin:/bin:/usr/sbin:/sbin:${PATH:-}"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
T="$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/clipboard-archive-release-test.XXXXXX")"
trap 'rm -rf "$T"' EXIT
FAILED=0
pass() { echo "PASS  $1"; }
failt() { echo "FAIL  $1"; FAILED=1; }

git clone --quiet --no-local "$ROOT" "$T/src"
git -C "$T/src" checkout --quiet "$(git -C "$ROOT" rev-parse HEAD)"
SRC="$T/src"

# A stand-in for /usr/bin/security that lists whatever identities we say.
fake_security() {
  local file="$T/security-$1"
  printf '#!/bin/sh\ncat <<"LIST"\n%s\nLIST\n' "$2" > "$file"
  chmod +x "$file"
  echo "$file"
}
NONE="$(fake_security none '  1) 2BDC70941494FDBFB7453585B23AE93C67BAAA5E "Some Local Signing"
     1 valid identities found')"
ONE="$(fake_security one '  1) 2BDC70941494FDBFB7453585B23AE93C67BAAA5E "Some Local Signing"
  2) 0B130CF4771A0AF92CE7C77C6C64BE92E7854F04 "Developer ID Application: Example Co (ABCDE12345)"
     2 valid identities found')"
TWO="$(fake_security two '  1) 2BDC70941494FDBFB7453585B23AE93C67BAAA5E "Developer ID Application: Example Co (ABCDE12345)"
  2) 0B130CF4771A0AF92CE7C77C6C64BE92E7854F04 "Developer ID Application: Other Co (ZYXWV54321)"
     2 valid identities found')"

# run NAME EXPECTED_RC PATTERN [env...] -- args...
run() {
  local name="$1" expected="$2" pattern="$3"; shift 3
  local envs=()
  while [ "$1" != "--" ]; do envs+=("$1"); shift; done
  shift
  set +e
  out="$(cd "$SRC" && env ${envs[@]+"${envs[@]}"} ./scripts/release.sh "$@" 2>&1)"
  rc=$?
  set -e
  if [ "$rc" -eq "$expected" ] && printf '%s' "$out" | tr '\n' ' ' | grep -Eq -- "$pattern"; then
    pass "$name (rc $rc)"
  else
    failt "$name (rc $rc, wanted $expected and /$pattern/)"
    printf '%s\n' "$out" | sed 's/^/      /' | tail -12
  fi
}

echo "## release.sh refusals (no build runs)"
run "developer-id with no certificate refuses, names it, builds nothing" 3 \
  "needs a 'Developer ID Application' certificate.*Nothing was built or signed" \
  CLIPBOARD_ARCHIVE_SECURITY_BIN="$NONE" -- --sign developer-id
[ ! -d "$SRC/releases" ] && pass "refusal left no release folder" || failt "refusal left a release folder"
run "developer-id with one certificate passes preflight" 0 \
  "signing: Developer ID Application: Example Co \(ABCDE12345\).*preflight ok" \
  CLIPBOARD_ARCHIVE_SECURITY_BIN="$ONE" -- --sign developer-id --preflight-only
run "two certificates and no --identity refuses" 3 "2 Developer ID Application identities" \
  CLIPBOARD_ARCHIVE_SECURITY_BIN="$TWO" -- --sign developer-id --preflight-only
run "--identity picks one of two" 0 "signing: Developer ID Application: Other Co" \
  CLIPBOARD_ARCHIVE_SECURITY_BIN="$TWO" -- --sign developer-id \
  --identity "Developer ID Application: Other Co (ZYXWV54321)" --preflight-only
run "--identity that is not in the keychain refuses" 3 "is not a valid Developer ID Application identity" \
  CLIPBOARD_ARCHIVE_SECURITY_BIN="$ONE" -- --sign developer-id --identity "Developer ID Application: Nobody" --preflight-only
run "--notarize without Developer ID refuses" 3 "Apple does not notarize ad hoc" -- --notarize --preflight-only
run "--notarize without a profile refuses" 3 "needs --notary-profile" \
  CLIPBOARD_ARCHIVE_SECURITY_BIN="$ONE" CLIPBOARD_ARCHIVE_NOTARY_PROFILE= -- --sign developer-id --notarize --preflight-only
run "a version with no CHANGELOG entry refuses" 3 "has no '## 9.9.9 build 1 - <date>' entry" -- --version 9.9.9 --build 1 --preflight-only
run "a plain-http feed refuses" 3 "must be https://" -- --feed-url http://updates.example.invalid/appcast.xml --preflight-only
run "a file: feed refuses" 3 "must be https://" -- --feed-url file:///tmp/appcast.xml --preflight-only
run "a feed without the public key file refuses" 3 "needs the update signing public key" \
  -- --feed-url https://updates.example.invalid/appcast.xml --ed-public-key-file "$T/missing.pub" --preflight-only
run "the committed public key is a valid key" 0 "updates: feed https://updates.example.invalid/appcast.xml.*preflight ok" \
  -- --feed-url https://updates.example.invalid/appcast.xml --preflight-only
printf 'not-a-key\n' > "$T/bad.pub"
run "a malformed public key refuses" 3 "is not a base64 Ed25519 public key" \
  -- --feed-url https://updates.example.invalid/appcast.xml --ed-public-key-file "$T/bad.pub" --preflight-only
/usr/bin/head -c 32 /dev/zero | /usr/bin/base64 > "$T/good.pub"
run "a good feed and key pass preflight" 0 "updates: feed https://updates.example.invalid/appcast.xml.*preflight ok" \
  -- --feed-url https://updates.example.invalid/appcast.xml --ed-public-key-file "$T/good.pub" --preflight-only
run "loopback http feed passes preflight" 0 "preflight ok" \
  -- --feed-url http://127.0.0.1:8080/appcast.xml --ed-public-key-file "$T/good.pub" --preflight-only
run "a feed with a user-info part refuses" 3 "must be https://" \
  -- --feed-url "http://127.0.0.1:80@evil.example.invalid/appcast.xml" --ed-public-key-file "$T/good.pub" --preflight-only
run "a plain-http download prefix refuses" 3 "--download-url-prefix must be https://" \
  -- --feed-url https://updates.example.invalid/appcast.xml --ed-public-key-file "$T/good.pub" \
  --download-url-prefix http://downloads.example.invalid --preflight-only
( umask 077; /usr/bin/head -c 32 /dev/urandom | /usr/bin/base64 > "$T/signer.key" )
/usr/bin/xcrun swift "$SRC/scripts/lib/ed25519-public-key.swift" "$T/signer.key" > "$T/signer.pub"
run "a signing key that does not match the built-in public key refuses" 3 "does not match" \
  -- --feed-url https://updates.example.invalid/appcast.xml --ed-public-key-file "$T/good.pub" \
  --download-url-prefix https://downloads.example.invalid --ed-key-file "$T/signer.key" --preflight-only
run "a signing key that matches passes preflight" 0 "signing key matches the public key built in.*preflight ok" \
  -- --feed-url https://updates.example.invalid/appcast.xml --ed-public-key-file "$T/signer.pub" \
  --download-url-prefix https://downloads.example.invalid --ed-key-file "$T/signer.key" --preflight-only
printf '#!/bin/sh\ncase "$1" in history) echo "No Keychain password item found for profile" >&2; exit 69;; esac\nexit 0\n' > "$T/notary-bad"
printf '#!/bin/sh\nexit 0\n' > "$T/notary-good"
chmod +x "$T/notary-bad" "$T/notary-good"
run "--notarize with a profile that does not work refuses" 3 "notary profile 'missing' is not usable" \
  CLIPBOARD_ARCHIVE_SECURITY_BIN="$ONE" CLIPBOARD_ARCHIVE_NOTARYTOOL="$T/notary-bad" \
  -- --sign developer-id --notarize --notary-profile missing --preflight-only
run "--notarize with a working profile passes preflight" 0 "notarize: profile clipboard-archive.*preflight ok" \
  CLIPBOARD_ARCHIVE_SECURITY_BIN="$ONE" CLIPBOARD_ARCHIVE_NOTARYTOOL="$T/notary-good" \
  -- --sign developer-id --notarize --notary-profile clipboard-archive --preflight-only
run "a download prefix without a feed refuses" 3 "writes an appcast nothing reads" \
  -- --download-url-prefix https://downloads.example.invalid --preflight-only
run "an unknown option is a usage error" 2 "unknown option" -- --frobnicate
echo "# local change" >> "$SRC/README.md"
run "uncommitted changes refuse" 3 "uncommitted changes" -- --preflight-only
run "--allow-dirty says DIRTY" 0 "\(DIRTY\).*preflight ok" -- --allow-dirty --preflight-only
git -C "$SRC" checkout --quiet README.md
touch "$SRC/Sources/ClipboardArchiveCore/Untracked.swift"
run "an untracked file counts as uncommitted" 3 "uncommitted changes" -- --preflight-only
rm -f "$SRC/Sources/ClipboardArchiveCore/Untracked.swift"

echo "## cached Sparkle tools"
cached="$ROOT/.build/sparkle-tools/2.10.0/Sparkle-2.10.0.tar.xz"
if [ -f "$cached" ]; then
  mkdir -p "$T/tools"
  cp "$cached" "$T/tools/"
  (cd "$SRC" && CLIPBOARD_ARCHIVE_SPARKLE_TOOLS="$T/tools" ./scripts/release.sh --fetch-sparkle-tools >/dev/null)
  good="$(shasum -a 256 "$T/tools/bin/sign_update" | cut -d' ' -f1)"
  echo tampered >> "$T/tools/bin/sign_update"
  (cd "$SRC" && CLIPBOARD_ARCHIVE_SPARKLE_TOOLS="$T/tools" ./scripts/release.sh --fetch-sparkle-tools >/dev/null)
  [ "$(shasum -a 256 "$T/tools/bin/sign_update" | cut -d' ' -f1)" = "$good" ] \
    && pass "a changed cached tool is replaced from the verified archive" || failt "a changed cached tool survived"
  printf 'x' >> "$T/tools/Sparkle-2.10.0.tar.xz"
  (cd "$SRC" && CLIPBOARD_ARCHIVE_SPARKLE_TOOLS="$T/tools" ./scripts/release.sh --fetch-sparkle-tools >/dev/null)
  [ "$(shasum -a 256 "$T/tools/Sparkle-2.10.0.tar.xz" | cut -d' ' -f1)" = "c2bf58aa8387266ac179357b1415d6f2635f044da8be41042af32425dae6da0c" ] \
    && pass "a changed cached archive is fetched again and re-verified" || failt "a changed cached archive was kept"
  mkdir -p "$T/foreign/bin"; echo keep > "$T/foreign/bin/mine"
  cp "$cached" "$T/foreign/"
  set +e; out="$(cd "$SRC" && CLIPBOARD_ARCHIVE_SPARKLE_TOOLS="$T/foreign" ./scripts/release.sh --fetch-sparkle-tools 2>&1)"; rc=$?; set -e
  [ "$rc" -ne 0 ] && [ -f "$T/foreign/bin/mine" ] \
    && pass "an override directory's own bin/ is left alone (rc $rc)" || failt "an override directory's bin/ was replaced"
else
  echo "SKIP  cached Sparkle tools (run ./scripts/release.sh --fetch-sparkle-tools once to enable)"
fi

echo "## release notes"
read -r V B <<<"$(cd "$SRC" && . scripts/lib/release-identity.sh && release_identity_newest CHANGELOG.md)"
python3 "$SRC/scripts/release_tools.py" notes "$SRC/CHANGELOG.md" "$V" "$B" --md "$T/n.md" --html "$T/n.html"
head -1 "$T/n.md" | grep -q "^# Clipboard Archive $V (build $B) - " && pass "notes title names version and build" || failt "notes title"
grep -q "<ul><li>" "$T/n.html" && pass "notes render the bullet list" || failt "notes list"
printf '# Changelog\n\n## 1.0.0 build 1 - 2026-01-01\n\n- Use `<script>` & friends safely.\n  Continued line.\n\n## 0.9.0 build 0 - 2025-01-01\n\n- older\n' > "$T/CHANGELOG.md"
python3 "$SRC/scripts/release_tools.py" notes "$T/CHANGELOG.md" 1.0.0 1 --md "$T/x.md" --html "$T/x.html"
grep -q '<code>&lt;script&gt;</code> &amp; friends safely. Continued line.' "$T/x.html" \
  && pass "notes escape HTML and join continuation lines" || { failt "notes escaping"; cat "$T/x.html"; }
grep -q "older" "$T/x.md" && failt "notes leaked the next entry" || pass "notes stop at the next entry"
set +e; python3 "$SRC/scripts/release_tools.py" notes "$T/CHANGELOG.md" 2.0.0 1 --md "$T/y.md" --html "$T/y.html" >/dev/null 2>&1; rc=$?; set -e
[ "$rc" -ne 0 ] && pass "notes for a missing entry fail" || failt "notes for a missing entry succeeded"

echo "## leak scan"
scan() {
  local name="$1" expected="$2" text="$3"
  printf '%s\n' "$text" > "$T/scan.txt"
  set +e; python3 "$SRC/scripts/release_tools.py" leak-scan "$T/scan.txt" >/dev/null 2>&1; rc=$?; set -e
  [ "$rc" -eq "$expected" ] && pass "$name" || failt "$name (rc $rc)"
}
scan "a home directory is a leak" 1 "built in /Users/somebody/src/app"
scan "an email address is a leak" 1 "contact someone@example.com"
scan "a tailnet host is a leak" 1 "https://box.tail1234.ts.net/feed"
scan "a tailnet address is a leak" 1 "http://100.86.1.2/feed"
scan "a private LAN address is a leak" 1 "http://192.168.1.20/feed"
scan "loopback and public text are fine" 0 "http://127.0.0.1:8080/appcast.xml https://github.com/example/releases"

echo "## local-only gate: package graph"
cp -R "$SRC" "$T/graph"
python3 - "$T/graph/Package.swift" <<'PY'
import sys
path = sys.argv[1]
text = open(path).read()
text = text.replace('dependencies: ["ClipboardArchiveCore", "ClipboardArchiveUpdateRules"]',
                    'dependencies: ["ClipboardArchiveCore", "ClipboardArchiveUpdateRules", .product(name: "Sparkle", package: "Sparkle")]', 1)
open(path, "w").write(text)
PY
set +e; out="$("$T/graph/scripts/check-local-only.sh" 2>&1)"; rc=$?; set -e
[ "$rc" -ne 0 ] && printf '%s' "$out" | grep -q "ClipboardArchiveMenuBar depends on Sparkle" \
  && pass "the app depending on the updater library fails the gate" || { failt "app->Sparkle not caught"; echo "$out"; }
rm -rf "$T/graph"; cp -R "$SRC" "$T/graph"
python3 - "$T/graph/Package.swift" <<'PY'
import sys
path = sys.argv[1]
text = open(path).read()
text = text.replace('"ClipboardArchiveUpdateRules",\n                .product(name: "Sparkle"',
                    '"ClipboardArchiveUpdateRules",\n                "ClipboardArchiveCore",\n                .product(name: "Sparkle"', 1)
open(path, "w").write(text)
PY
set +e; out="$("$T/graph/scripts/check-local-only.sh" 2>&1)"; rc=$?; set -e
[ "$rc" -ne 0 ] && printf '%s' "$out" | grep -q "ClipboardArchiveUpdater depends on ClipboardArchiveCore" \
  && pass "the helper depending on the core fails the gate" || { failt "helper->core not caught"; echo "$out"; }
rm -rf "$T/graph"; cp -R "$SRC" "$T/graph"
printf '\nlet _ = NSPasteboard.general\n' >> "$T/graph/Sources/ClipboardArchiveUpdater/main.swift"
set +e; out="$("$T/graph/scripts/check-local-only.sh" 2>&1)"; rc=$?; set -e
[ "$rc" -ne 0 ] && printf '%s' "$out" | grep -q "reach for the clipboard" \
  && pass "the helper touching the pasteboard fails the gate" || { failt "helper->pasteboard not caught"; echo "$out"; }
set +e; out="$(PATH=/usr/bin:/bin "$SRC/scripts/check-local-only.sh" 2>&1)"; rc=$?; set -e
[ "$rc" -ne 0 ] && printf '%s' "$out" | grep -q "ripgrep (rg) is required" \
  && pass "the gate fails closed without ripgrep" || { failt "gate passed without ripgrep"; echo "$out"; }
set +e; out="$("$SRC/scripts/check-local-only.sh" 2>&1)"; rc=$?; set -e
[ "$rc" -eq 0 ] && pass "HEAD passes the gate" || { failt "HEAD fails the gate"; echo "$out"; }

if [ "$FAILED" -eq 0 ]; then
  echo "release tests ok"
else
  echo "release tests FAILED" >&2
  exit 1
fi
